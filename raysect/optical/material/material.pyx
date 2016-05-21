# cython: language_level=3

# Copyright (c) 2014, Dr Alex Meakins, Raysect Project
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

from raysect.core.math.random cimport probability
from raysect.core.math cimport new_affinematrix3d

# TODO: move surface_to_primitive calculation to material from intersection, convert eval_surface API back to list of intersection parameters

cdef class Material(CoreMaterial):

    def __init__(self):
        super().__init__()
        self._importance = 0.0

    property importance:

        def __get__(self):
            return self._importance

        def __set__(self, value):
            if value < 0:
                raise ValueError("Material sampling importance cannot be less than zero.")
            self._importance = value
            self.notify_material_change()

    cpdef Spectrum evaluate_surface(self, World world, Ray ray, Primitive primitive, Point3D hit_point,
                                    bint exiting, Point3D inside_point, Point3D outside_point,
                                    Normal3D normal, AffineMatrix3D world_to_primitive, AffineMatrix3D primitive_to_world):
        raise NotImplementedError("Material virtual method evaluate_surface() has not been implemented.")

    cpdef Spectrum evaluate_volume(self, Spectrum spectrum, World world, Ray ray, Primitive primitive,
                                   Point3D start_point, Point3D end_point,
                                   AffineMatrix3D world_to_primitive, AffineMatrix3D primitive_to_world):
        raise NotImplementedError("Material virtual method evaluate_volume() has not been implemented.")


cdef class ContinuousBSDF(Material):

    cpdef Spectrum evaluate_surface(self, World world, Ray ray, Primitive primitive, Point3D p_hit_point,
                                    bint exiting, Point3D p_inside_point, Point3D p_outside_point,
                                    Normal3D p_normal, AffineMatrix3D world_to_primitive, AffineMatrix3D primitive_to_world):

        cdef:
            double pdf, pdf_importance, pdf_bsdf
            Vector3D w_outgoing, s_incoming, s_outgoing
            Point3D w_hit_point
            AffineMatrix3D world_to_surface, surface_to_world, primitive_to_surface, surface_to_primitive

        # obtain surface space transforms
        primitive_to_surface, surface_to_primitive = self._generate_surface_transforms(p_normal)
        world_to_surface = primitive_to_surface.mul(world_to_primitive)
        surface_to_world = primitive_to_world.mul(surface_to_primitive)

        # convert ray direction to surface space incident direction
        s_incoming = ray.direction.transform(world_to_surface).neg()

        # convert ray launch points to world space
        w_inside_point = p_inside_point.transform(primitive_to_world)
        w_outside_point = p_outside_point.transform(primitive_to_world)

        if ray.importance_sampling and world.has_important_primitives():

            w_hit_point = p_hit_point.transform(primitive_to_world)

            # multiple importance sampling
            if probability(ray.get_important_path_weight()):

                # sample important path pdf
                w_outgoing = world.important_direction_sample(w_hit_point)
                s_outgoing = w_outgoing.transform(world_to_surface)

            else:

                # sample bsdf pdf
                s_outgoing = self.sample(s_incoming, exiting)
                w_outgoing = s_outgoing.transform(surface_to_world)

            # compute combined pdf
            pdf_important = world.important_direction_pdf(w_hit_point, w_outgoing)
            pdf_bsdf = self.pdf(s_incoming, s_outgoing, exiting)
            pdf = ray.get_important_path_weight() * pdf_important + (1 - ray.get_important_path_weight()) * pdf_bsdf

            # evaluate bsdf and normalise
            spectrum = self.evaluate_shading(world, ray, s_incoming, s_outgoing, w_inside_point, w_outside_point, exiting, world_to_surface, surface_to_world)
            spectrum.mul_scalar(1 / pdf)
            return spectrum

        else:

            # bsdf sampling
            s_outgoing = self.sample(s_incoming, exiting)
            spectrum = self.evaluate_shading(world, ray, s_incoming, s_outgoing, w_inside_point, w_outside_point, exiting, world_to_surface, surface_to_world)
            pdf = self.pdf(s_incoming, s_outgoing, exiting)
            spectrum.mul_scalar(1 / pdf)
            return spectrum

    cpdef double pdf(self, Vector3D incoming, Vector3D outgoing, bint back_face):
        raise NotImplementedError("Virtual method pdf() has not been implemented.")

    cpdef Vector3D sample(self, Vector3D incoming, bint back_face):
        raise NotImplementedError("Virtual method sample() has not been implemented.")

    cpdef Spectrum evaluate_shading(self, World world, Ray ray, Vector3D s_incoming, Vector3D s_outgoing,
                                    Point3D w_inside_point, Point3D w_outside_point, bint back_face,
                                    AffineMatrix3D world_to_surface, AffineMatrix3D surface_to_world):
        raise NotImplementedError("Virtual method evaluate_shading() has not been implemented.")

    cdef inline tuple _generate_surface_transforms(self, Normal3D normal):
        """
        Calculates and populates the surface space transform attributes.
        """

        cdef:
            Vector3D tangent, bitangent
            AffineMatrix3D primitive_to_surface, surface_to_primitive

        # TODO: when UV information added, align the x-axis with the u-coordinate and y-axis with the v-coordinate
        tangent = normal.orthogonal()
        bitangent = normal.cross(tangent)

        primitive_to_surface = new_affinematrix3d(
            tangent.x, tangent.y, tangent.z, 0.0,
            bitangent.x, bitangent.y, bitangent.z, 0.0,
            normal.x, normal.y, normal.z, 0.0,
            0.0, 0.0, 0.0, 1.0
        )

        surface_to_primitive = new_affinematrix3d(
            tangent.x, bitangent.x, normal.x, 0.0,
            tangent.y, bitangent.y, normal.y, 0.0,
            tangent.z, bitangent.z, normal.z, 0.0,
            0.0, 0.0, 0.0, 1.0
        )

        return primitive_to_surface, surface_to_primitive


cdef class NullSurface(Material):

    cpdef Spectrum evaluate_surface(self, World world, Ray ray, Primitive primitive, Point3D hit_point,
                                    bint exiting, Point3D inside_point, Point3D outside_point,
                                    Normal3D normal, AffineMatrix3D world_to_primitive, AffineMatrix3D primitive_to_world):

        cdef:
            Point3D origin
            Ray daughter_ray

        # are we entering or leaving surface?
        if exiting:
            origin = outside_point.transform(primitive_to_world)
        else:
            origin = inside_point.transform(primitive_to_world)

        daughter_ray = ray.spawn_daughter(origin, ray.direction)

        # do not count null surfaces in ray depth
        daughter_ray.depth -= 1

        # prevent extinction on a null surface
        return daughter_ray.trace(world, keep_alive=True)


cdef class NullVolume(Material):

    cpdef Spectrum evaluate_volume(self, Spectrum spectrum, World world, Ray ray, Primitive primitive,
                                   Point3D start_point, Point3D end_point,
                                   AffineMatrix3D world_to_primitive, AffineMatrix3D primitive_to_world):

        # no volume contribution
        return spectrum