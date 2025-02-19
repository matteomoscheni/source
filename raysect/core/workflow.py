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

from multiprocessing import Process, cpu_count, SimpleQueue
from raysect.core.math import random


class RenderEngine:
    """
    Provides a common rendering workflow interface.

    This is a base class, its functionality must be implemented fully by the deriving class.

    This class provides a rendering workflow that abstracts away the underlying
    system performing the work. It is intended that render engines may be built
    that provide rendering on single cores, multi-cores (SMP) and clusters.

    The basic workflow is as follows. The render task is split into small,
    self-contained chunks of work - 'tasks'. These tasks are passed to the
    render engine which distributes the work to the available computing
    resources. These discrete computing resources are know as "workers".
    Workers process one task at a time and return their result to the render
    engine. When results are received the render engine assembles them into
    the final result.

    This workflow is implemented by supplying a set of tasks and two methods to
    the render engines' run() method which processes those tasks. The functions
    supplied to the run() method may be given additional args and kwargs.

    A worker calls render for each task object received. render has the following signature: ::

        def render(task, *render_args, **render_kwargs)

    where args and kwargs are additional arguments supplied by the user.

    Similarly, the worker calls update() for the results generated by a call to
    render(). Update() has the following signature: ::

        def update(results, *update_args, **update_kwargs)

    where args and kwargs are additional arguments supplied by the user.

    The render() function must return an object representing the results,
    this must be a picklable python object.
    """

    def run(self, tasks, render, update, render_args=(), render_kwargs={}, update_args=(), update_kwargs={}):
        """
        Starts the render engine executing the requested tasks.

        :param list tasks: List of user defined tuples that describe the task to execute.
        :param object render: Callable python object that executes the tasks.
        :param object update: Callable python object that is called following a render task and must be
          used to update the internal state of the object requesting work.
        :param tuple render_args: Additional arguments to pass to user defined render function.
        :param tuple render_kwargs: Additional keyword arguments to pass to user defined render function.
        :param tuple update_args: Additional arguments to pass to user defined update function.
        :param tuple update_kwargs: Additional keyword arguments to pass to user defined update function.
        """
        raise NotImplementedError("Virtual method must be implemented in sub-class.")

    def worker_count(self):
        """
        Returns the number of workers in use by this engine.
        """
        raise NotImplementedError("Virtual method must be implemented in sub-class.")


class SerialEngine(RenderEngine):
    """
    Render engine for running on a single CPU processor.

    This engine is useful for debugging.

        >>> from raysect.core import SerialEngine
        >>> from raysect.optical.observer import PinholeCamera
        >>>
        >>> camera = PinholeCamera((512, 512))
        >>> camera.render_engine = SerialEngine()
    """

    def run(self, tasks, render, update, render_args=(), render_kwargs={}, update_args=(), update_kwargs={}):

        for task in tasks:
            result = render(task, *render_args, **render_kwargs)
            update(result, *update_args, **update_kwargs)

    def worker_count(self):
        return 1


class MulticoreEngine(RenderEngine):
    """
    A render engine for distributing work across multiple CPU cores.

    The number of processes spawned by this render engine is controlled via
    the processes attribute. This can also be set at object initialisation.
   
    If the processes attribute is set to None (the default), the render engine
    will automatically set the number pf processes to be equal to the number
    of CPU cores detected on the machine.
    
    :param processes: The number of worker processes, or None to use all available cores (default).

    .. code-block:: pycon

        >>> from raysect.core import MulticoreEngine
        >>> from raysect.optical.observer import PinholeCamera
        >>>
        >>> camera = PinholeCamera((512, 512))
        >>>
        >>> # allowing the camera to use all available CPU cores.
        >>> camera.render_engine = MulticoreEngine()
        >>>
        >>> # or forcing the render engine to use a specific number of CPU processes
        >>> camera.render_engine = MulticoreEngine(processes=8)
    """

    def __init__(self, processes=None):
        super().__init__()
        self._processes = -1
        self.processes = processes

    @property
    def processes(self):
        return self._processes

    @processes.setter
    def processes(self, value):
        if value is None:
            self._processes = cpu_count()
        else:
            value = int(value)
            if value <= 0:
                raise ValueError('Number of concurrent worker processes must be greater than zero.')
            self._processes = value

    def run(self, tasks, render, update, render_args=(), render_kwargs={}, update_args=(), update_kwargs={}):

        # establish ipc queues using a manager process
        task_queue = SimpleQueue()
        result_queue = SimpleQueue()

        # start process to generate image samples
        producer = Process(target=self._producer, args=(tasks, task_queue))
        producer.start()

        # start worker processes
        workers = []
        for pid in range(self._processes):
            p = Process(target=self._worker, args=(render, render_args, render_kwargs, task_queue, result_queue))
            p.start()
            workers.append(p)

        # consume results
        for _ in tasks:
            result = result_queue.get()
            update(result, *update_args, **update_kwargs)

        # shutdown workers
        for _ in workers:
            task_queue.put(None)

    def worker_count(self):
        return self._processes

    def _producer(self, tasks, task_queue):
        for task in tasks:
            task_queue.put(task)

    def _worker(self, render, args, kwargs, task_queue, result_queue):

        # re-seed the random number generator to prevent all workers inheriting the same sequence
        random.seed()

        # process tasks
        while True:

            task = task_queue.get()

            # have we been commanded to shutdown?
            if task is None:
                break

            result = render(task, *args, **kwargs)
            result_queue.put(result)


if __name__ == '__main__':

    from time import time

    class Job:

        def __init__(self, engine=None):
            self.total = 0
            self.engine = engine if engine else MulticoreEngine()

        def run(self, v):
            self.total = 0
            self.engine.run(list(range(v)), self.render, self.update, render_args=(10000,))
            return self.total

        def render(self, task, count):
            sum = 0
            for i in range(count):
                sum += 1 / count
            return sum

        def update(self, result):
            self.total += result

    n = 2000

    t = time()
    j = Job(SerialEngine())
    print(j.run(n), time() - t)

    t = time()
    j = Job(MulticoreEngine())
    print(j.run(n), time() - t)
