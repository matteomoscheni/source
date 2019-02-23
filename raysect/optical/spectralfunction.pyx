# cython: language_level=3

# Copyright (c) 2014-2018, Dr Alex Meakins, Raysect Project
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
#     1. Redistributions of source code must retain the above copyright notice,
#        this list of conditions and the following disclaimer.
#
#     2. Redistributions in binary form must reproduce the above copyright
#        notice, this list of conditions and the following disclaimer in the
#        documentation and/or other materials provided with the distribution.
#
#     3. Neither the name of the Raysect Project nor the names of its
#        contributors may be used to endorse or promote products derived from
#        this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

cimport cython
from raysect.core.math.cython cimport interpolate, integrate
from numpy import array, float64, argsort
from numpy cimport PyArray_SimpleNew, PyArray_FILLWBYTE, NPY_FLOAT64, npy_intp, import_array
from libc.math cimport ceil

# required by numpy c-api
import_array()


# TODO: add a note about how the caching works, particularly that users must cache clear if function parameters change
@cython.freelist(512)
cdef class SpectralFunction:
    """
    SpectralFunction abstract base class.

    A common interface for representing optical properties that are a function
    of wavelength. It provides methods for sampling, integrating and averaging
    a spectral function over specified wavelength ranges. The optical package
    uses SpectralFunctions to represent a number of different wavelength
    dependent optical properties, for example emission spectra, refractive
    indices and attenuation curves.

    Deriving classes must implement the integrate method.

    It is also recommended that subclasses implement __call__(). This should
    accept a single argument - wavelength - and return a single sample of the
    function at that wavelength. The units of wavelength are nanometers.

    A number of utility sub-classes exist to simplify SpectralFunction
    development.

    see also: NumericallyIntegratedSF, InterpolatedSF, ConstantSF, Spectrum
    """

    def __init__(self):
        self._average_cache_init()
        self._sample_cache_init()

    def __getstate__(self):

        return (
            self._average_cache,
            self._average_cache_min_wvl,
            self._average_cache_max_wvl,
            self._sample_cache,
            self._sample_cache_min_wvl,
            self._sample_cache_max_wvl,
            self._sample_cache_num_samp
        )

    def __setstate__(self, state):

        (
            self._average_cache,
            self._average_cache_min_wvl,
            self._average_cache_max_wvl,
            self._sample_cache,
            self._sample_cache_min_wvl,
            self._sample_cache_max_wvl,
            self._sample_cache_num_samp
        ) = state

        # rebuild memory views
        self._sample_cache_mv = self._sample_cache

    # must override automatic __reduce__ method generated by cython for the base class
    def __reduce__(self):
        return self.__new__, (self.__class__, ), self.__getstate__()

    cpdef double evaluate(self, double wavelength):
        """
        Evaluate the spectral function f(wavelength)

        :param float wavelength: Wavelength in nanometers.
        :rtype: float
        """
        raise NotImplementedError("Virtual method evaluate() not implemented.")

    def __call__(self, double wavelength):
        """
        Evaluate the spectral function f(wavelength)

        :param float wavelength: Wavelength in nanometers.
        :rtype: float
        """
        return self.evaluate(wavelength)

    cpdef double integrate(self, double min_wavelength, double max_wavelength):
        """
        Calculates the integrated radiance over the specified spectral range.

        Virtual method, to be implemented in child classes.

        :param float min_wavelength: The minimum wavelength in nanometers
        :param float max_wavelength: The maximum wavelength in nanometers
        :return: Integrated radiance in W/m^2/str
        :rtype: float

        .. code-block:: pycon

            >>> spectrum = ray.trace(world)
            >>> spectrum.integrate(400, 700)
            328.50926129107023
        """
        raise NotImplementedError("Virtual method integrate() not implemented.")

    @cython.cdivision(True)
    cpdef double average(self, double min_wavelength, double max_wavelength):
        """
        Average radiance over the requested spectral range (W/m^2/sr/nm).

        Virtual method, to be implemented in child classes.

        :param float min_wavelength: lower wavelength for calculation
        :param float max_wavelength: upper wavelength for calculation
        :rtype: float

        .. code-block:: pycon

            >>> spectrum = ray.trace(world)
            >>> spectrum.average(400, 700)
            1.095030870970234
        """

        # is a cached average already available?
        if self._average_cache_valid(min_wavelength, max_wavelength):
            return self._average_cache_get()

        average = self.integrate(min_wavelength, max_wavelength) / (max_wavelength - min_wavelength)

        # update cache
        self._average_cache_set(min_wavelength, max_wavelength, average)

        return average

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cpdef ndarray sample(self, double min_wavelength, double max_wavelength, int bins):
        """
        Re-sample the spectral function with a new wavelength range and resolution.

        :param float min_wavelength: lower wavelength for calculation
        :param float max_wavelength: upper wavelength for calculation
        :param int bins: The number of spectral bins
        :rtype: ndarray

        .. code-block:: pycon

            >>> spectrum
            <raysect.optical.spectrum.Spectrum at 0x7f56c22bd8b8>
            >>> spectrum.min_wavelength, spectrum.max_wavelength
            (375.0, 785.0)
            >>> sub_spectrum = spectrum.sample(450, 550, 100)
        """

        cdef:
            ndarray samples
            double[::1] samples_mv
            npy_intp size, index
            double lower, upper, delta, reciprocal

        # are cached samples already available?
        if self._sample_cache_valid(min_wavelength, max_wavelength, bins):
            return self._sample_cache_get_array()

        # create new sample ndarray and obtain a memoryview for fast access
        size = bins
        samples = PyArray_SimpleNew(1, &size, NPY_FLOAT64)
        PyArray_FILLWBYTE(samples, 0)
        sample_mv = samples

        # re-sample by averaging data across each bin
        delta = (max_wavelength - min_wavelength) / bins
        lower = min_wavelength
        reciprocal = 1.0 / delta
        for index in range(bins):
            upper = min_wavelength + (index + 1) * delta
            sample_mv[index] = reciprocal * self.integrate(lower, upper)
            lower = upper

        # update cache
        self._sample_cache_set(min_wavelength, max_wavelength, bins, samples, sample_mv)

        return samples

    cdef double[::1] sample_mv(self, double min_wavelength, double max_wavelength, int bins):
        """
        Re-sample the spectral function with a new wavelength range and resolution.
        
        This method is only available from cython. Behaves as sample() except
        returns a memoryview for fast access.        

        :param float min_wavelength: lower wavelength for calculation
        :param float max_wavelength: upper wavelength for calculation
        :param int bins: The number of spectral bins
        :rtype: Memoryview.
        """

        if self._sample_cache_valid(min_wavelength, max_wavelength, bins):
            return self._sample_cache_get_mv()

        # populate cache
        self.sample(min_wavelength, max_wavelength, bins)
        return self._sample_cache_get_mv()

    cdef void _average_cache_init(self):
        """
        Initialises the average cache.
        """

        # initialise cache with invalid values
        self._average_cache = 0
        self._average_cache_min_wvl = -1
        self._average_cache_max_wvl = -1

    cdef bint _average_cache_valid(self, double min_wavelength, double max_wavelength):
        """
        Returns true if a suitable cached average is available.
        """

        return (
            self._average_cache_min_wvl == min_wavelength and
            self._average_cache_max_wvl == max_wavelength
        )

    cdef double _average_cache_get(self):
        """
        Returns the cached value.
        
        The value is undefined if called when _average_cache_valid() is False.
        """

        return self._average_cache

    cdef void _average_cache_set(self, double min_wavelength, double max_wavelength, double average):
        """
        Updates the cached average.
        """

        self._average_cache = average
        self._average_cache_min_wvl = min_wavelength
        self._average_cache_max_wvl = max_wavelength

    cdef void _sample_cache_init(self):
        """
        Initialises the sample cache.
        """

        # initialise cache with invalid values
        self._sample_cache = None
        self._sample_cache_mv = None
        self._sample_cache_min_wvl = -1
        self._sample_cache_max_wvl = -1
        self._sample_cache_num_samp = -1

    cdef bint _sample_cache_valid(self, double min_wavelength, double max_wavelength, int bins):
        """
        Returns true if a suitable cached samples are available.
        """

        return (
            self._sample_cache_min_wvl == min_wavelength and
            self._sample_cache_max_wvl == max_wavelength and
            self._sample_cache_num_samp == bins
        )

    cdef ndarray _sample_cache_get_array(self):
        """
        Returns the cached sample array.
        
        The value is undefined if called when _average_cache_valid() is False.
        """

        return self._sample_cache

    cdef double[::1] _sample_cache_get_mv(self):
        """
        Returns the cached sample array memoryview.
        
        The value is undefined if called when _average_cache_valid() is False.
        """

        return self._sample_cache_mv

    cdef void _sample_cache_set(self, double min_wavelength, double max_wavelength, int bins, ndarray samples, double[::1] samples_mv):
        """
        Updates the cached sample array and memoryview.
        """

        self._sample_cache = samples
        self._sample_cache_mv = samples_mv
        self._sample_cache_min_wvl = min_wavelength
        self._sample_cache_max_wvl = max_wavelength
        self._sample_cache_num_samp = bins


cdef class NumericallyIntegratedSF(SpectralFunction):
    """
    Numerically integrates a supplied function.

    This abstract class provides an implementation of the integrate method that
    numerically integrates a supplied function (typically a non-integrable
    analytical function). The function to numerically integrate is supplied by
    sub-classing this class and implementing the function() method.

    The function is numerically sampled at regular intervals. A sampling
    resolution may be specified in the class constructor (default: 1 sample/nm).

    :param double sample_resolution: The numerical sampling resolution in nanometers.
    """

    def __init__(self, double sample_resolution=1.0):

        super().__init__()

        if sample_resolution <= 0:
            raise ValueError("Sampling resolution must be greater than zero.")

        self.sample_resolution = sample_resolution

    def __getstate__(self):
        return self.sample_resolution, super().__getstate__()

    def __setstate__(self, state):
        self.sample_resolution, super_state = state
        super().__setstate__(super_state)

    def __reduce__(self):
        return self.__new__, (self.__class__, ), self.__getstate__()

    cpdef double evaluate(self, double wavelength):
        """
        Evaluate the spectral function f(wavelength)

        :param float wavelength: Wavelength in nanometers.
        :rtype: float
        """

        return self.function(wavelength)

    cpdef double integrate(self, double min_wavelength, double max_wavelength):
        """
        Calculates the integrated radiance over the specified spectral range.

        :param float min_wavelength: The minimum wavelength in nanometers
        :param float max_wavelength: The maximum wavelength in nanometers
        :return: Integrated radiance in W/m^2/str
        :rtype: float
        """

        cdef:
            double delta, centre, sum
            int samples, i

        # calculate number of samples over range
        samples = <int> ceil((max_wavelength - min_wavelength) / self.sample_resolution)
        samples = max(samples, 1)

        # sample the function and integrate
        # TODO: improve this algorithm - e.g. simpsons rule
        # TODO: rewrite this to sample values into array and then pass this to the cython integrate function - then improve that function as it will improve all the code that uses it
        sum = 0.0
        delta = (max_wavelength - min_wavelength) / samples
        for i in range(samples):
            centre = min_wavelength + (0.5 + i) * delta
            sum += self.function(centre) * delta

        return sum

    cpdef double function(self, double wavelength):
        """
        Function to numerically integrate.

        This is a virtual method and must be implemented through sub-classing.

        :param double wavelength: Wavelength in nanometers.
        :return: Function value at the specified wavelength.
        """

        raise NotImplementedError("Virtual method function() not implemented.")


cdef class InterpolatedSF(SpectralFunction):
    """
    Linearly interpolated spectral function.

    Spectral function defined by samples of regular or irregular spacing, ends
    are extrapolated. You must set the ends to zero if you want the function to
    go to zero at the edges!

    wavelengths and samples will be sorted during initialisation.

    If normalise is set to True the data is rescaled so the integrated area
    of the spectral function over the full range of the input data is
    normalised to 1.0.

    :param object wavelengths: 1D array of wavelengths in nanometers.
    :param object samples: 1D array of spectral samples.
    :param bool normalise: True/false toggle for whether to normalise the
      spectral function so its integral equals 1.

    .. code-block:: pycon

        >>> from raysect.optical import InterpolatedSF
        >>>
        >>> # defining a set of spectral filters
        >>> filter_red = InterpolatedSF([100, 650, 660, 670, 680, 800], [0, 0, 1, 1, 0, 0])
        >>> filter_green = InterpolatedSF([100, 530, 540, 550, 560, 800], [0, 0, 1, 1, 0, 0])
        >>> filter_blue = InterpolatedSF([100, 480, 490, 500, 510, 800], [0, 0, 1, 1, 0, 0])
    """

    def __init__(self, object wavelengths, object samples, normalise=False):

        super().__init__()

        self.wavelengths = array(wavelengths, dtype=float64)
        self.samples = array(samples, dtype=float64)

        if self.wavelengths.ndim != 1:
            raise ValueError("Wavelength array must be 1D.")

        if self.samples.shape[0] != self.wavelengths.shape[0]:
            raise ValueError("Wavelength and sample arrays must be the same length.")

        # sort arrays by increasing wavelength
        indices = argsort(self.wavelengths)
        self.wavelengths = self.wavelengths[indices]
        self.samples = self.samples[indices]

        # obtain memory views
        self.wavelengths_mv = self.wavelengths
        self.samples_mv = self.samples

        if normalise:
            self.samples /= self.integrate(self.wavelengths.min(), self.wavelengths.max())

    def __getstate__(self):
        return self.wavelengths, self.samples, super().__getstate__()

    def __setstate__(self, state):

        self.wavelengths, self.samples, super_state = state
        super().__setstate__(super_state)

        # rebuild memory views
        self.wavelengths_mv = self.wavelengths
        self.samples_mv = self.samples

    def __reduce__(self):
        return self.__new__, (self.__class__, ), self.__getstate__()

    @cython.initializedcheck(False)
    cpdef double evaluate(self, double wavelength):
        """
        Evaluate the spectral function f(wavelength)

        :param float wavelength: Wavelength in nanometers.
        :rtype: float
        """

        return interpolate(self.wavelengths_mv, self.samples_mv, wavelength)

    @cython.initializedcheck(False)
    cpdef double integrate(self, double min_wavelength, double max_wavelength):
        """
        Calculates the integrated radiance over the specified spectral range.

        :param float min_wavelength: The minimum wavelength in nanometers
        :param float max_wavelength: The maximum wavelength in nanometers
        :return: Integrated radiance in W/m^2/str
        :rtype: float
        """
        return integrate(self.wavelengths_mv, self.samples_mv, min_wavelength, max_wavelength)


cdef class ConstantSF(SpectralFunction):
    """
    Constant value spectral function

    :param float value: Constant radiance value

    .. code-block:: pycon

        >>> from raysect.optical import ConstantSF
        >>>
        >>> unity_spectral_function = ConstantSF(1.0)
    """

    def __init__(self, double value):

        super().__init__()
        self.value = value

    def __getstate__(self):
        return self.value, super().__getstate__()

    def __setstate__(self, state):
        self.value, super_state = state
        super().__setstate__(super_state)

    def __reduce__(self):
        return self.__new__, (self.__class__, ), self.__getstate__()

    cpdef double evaluate(self, double wavelength):
        """
        Evaluate the spectral function f(wavelength)

        :param float wavelength: Wavelength in nanometers.
        :rtype: float
        """
        return self.value

    cpdef double integrate(self, double min_wavelength, double max_wavelength):
        """
        Calculates the integrated radiance over the specified spectral range.

        :param float min_wavelength: The minimum wavelength in nanometers
        :param float max_wavelength: The maximum wavelength in nanometers
        :return: Integrated radiance in W/m^2/str
        :rtype: float
        """
        return self.value * (max_wavelength - min_wavelength)

    cpdef double average(self, double min_wavelength, double max_wavelength):
        """
        Average radiance over the requested spectral range (W/m^2/sr/nm).

        :param float min_wavelength: lower wavelength for calculation
        :param float max_wavelength: upper wavelength for calculation
        :rtype: float
        """
        return self.value

    cpdef ndarray sample(self, double min_wavelength, double max_wavelength, int bins):
        """
        Re-sample the spectral function with a new wavelength range and resolution.

        :param float min_wavelength: lower wavelength for calculation
        :param float max_wavelength: upper wavelength for calculation
        :param int bins: The number of spectral bins
        :rtype: ndarray
        """

        cdef:
            ndarray samples
            npy_intp size
            double[::1] samples_mv

        # are cached samples already available?
        if self._sample_cache_valid(min_wavelength, max_wavelength, bins):
            return self._sample_cache_get_array()

        # create new sample ndarray and obtain a memoryview for fast access
        size = bins
        samples = PyArray_SimpleNew(1, &size, NPY_FLOAT64)
        PyArray_FILLWBYTE(samples, 0)
        samples_mv = samples

        # generate samples
        samples_mv[:] = self.value

        # update cache
        self._sample_cache_set(min_wavelength, max_wavelength, bins, samples, samples_mv)

        return samples
