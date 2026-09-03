# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, Modular Inc. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ===----------------------------------------------------------------------=== #

from std.time import (
    monotonic,
    perf_counter,
    perf_counter_ns,
    sleep,
    time_function,
)

from std.time.time import (
    _CTimeSpec,
    _process_cputime_nanoseconds,
    _realtime_nanoseconds,
    _thread_cputime_nanoseconds,
)
from std.testing import assert_equal, assert_true, TestSuite


@always_inline
def time_me():
    sleep(1.0)


@always_inline
def time_me_templated[
    dtype: DType,
]():
    time_me()
    return


# Check that time_function works on templated function
def time_templated_function[
    dtype: DType,
]() -> Int:
    return Int(time_function(time_me_templated[dtype]))


def time_capturing_function(iters: Int) -> Int:
    def time_fn():
        sleep(1.0)

    return Int(time_function(time_fn))


def test_time() raises:
    comptime ns_per_sec = 1_000_000_000

    assert_true(perf_counter() > 0)
    assert_true(perf_counter_ns() > 0)
    assert_true(monotonic() > 0)

    var t1 = time_function(time_me)
    assert_true(t1 > 1 * ns_per_sec)
    assert_true(t1 < 10 * ns_per_sec)

    var t2 = time_templated_function[.float32]()
    assert_true(t2 > 1 * ns_per_sec)
    assert_true(t2 < 10 * ns_per_sec)

    var t3 = time_capturing_function(42)
    assert_true(t3 > 1 * ns_per_sec)
    assert_true(t3 < 10 * ns_per_sec)

    # test perf_counter_ns() directly since time_function doesn't use now on windows
    var t4 = perf_counter_ns()
    time_me()
    var t5 = perf_counter_ns()
    assert_true((t5 - t4) > 1 * ns_per_sec)
    assert_true((t5 - t4) < 10 * ns_per_sec)


def test_ctimespec_as_nanoseconds() raises:
    assert_equal(_CTimeSpec().as_nanoseconds(), 0)
    assert_equal(_CTimeSpec(0, 1).as_nanoseconds(), 1)
    assert_equal(_CTimeSpec(1, 0).as_nanoseconds(), 1_000_000_000)
    assert_equal(_CTimeSpec(1, 500_000_000).as_nanoseconds(), 1_500_000_000)


def test_realtime_is_a_plausible_wall_clock() raises:
    """The realtime clock counts from the Unix epoch on every platform.

    Nothing else in this file looks at the realtime clock, and it is the one
    clock here that has an agreed zero rather than an arbitrary one, so it is
    the only one where an answer can be checked rather than just compared to
    another answer from the same clock. Windows makes that worth doing: it
    counts hundred nanosecond ticks from 1601 and the shift to 1970 has to be
    applied by hand, and getting it wrong lands three and a half centuries out,
    which is a long way from anything either of these bounds allows.
    """
    comptime start_of_2020 = 1_577_836_800_000_000_000
    comptime start_of_2100 = 4_102_444_800_000_000_000

    var now = _realtime_nanoseconds()
    assert_true(now > start_of_2020, "realtime clock is before 2020")
    assert_true(now < start_of_2100, "realtime clock is after 2100")


def test_cputime_clocks_advance() raises:
    """Burning CPU has to show up on the CPU time clocks.

    Deliberately spinning rather than sleeping, because sleeping is the thing
    that separates these clocks from the monotonic one and a sleeping process
    should move the monotonic clock without moving these. The spin runs long
    enough to clear the coarsest reporting interval any of the platforms uses,
    which is about sixteen milliseconds on Windows, by a wide margin.
    """
    comptime spin_ns = 300_000_000

    var process_before = _process_cputime_nanoseconds()
    var thread_before = _thread_cputime_nanoseconds()
    assert_true(process_before >= 0, "process CPU time is negative")
    assert_true(thread_before >= 0, "thread CPU time is negative")

    var deadline = monotonic() + spin_ns
    var sink = 0
    while monotonic() < deadline:
        sink += 1
    assert_true(sink > 0, "the spin loop did not run")

    assert_true(
        _process_cputime_nanoseconds() > process_before,
        "process CPU time did not advance while burning CPU",
    )
    assert_true(
        _thread_cputime_nanoseconds() > thread_before,
        "thread CPU time did not advance while burning CPU",
    )


def test_sleep_is_finer_than_a_millisecond() raises:
    """A sleep shorter than a millisecond has to be shorter than a millisecond.

    This is the one assertion in the file that a plausible implementation
    fails. The obvious way to write `sleep` on Windows is `Sleep`, which takes
    whole milliseconds and rounds up to the system timer interval, so a request
    for two hundred microseconds becomes about sixteen milliseconds and the
    caller is told nothing. Forty of them is half a second that way and well
    under a tenth of a second when the sleep does what it says.

    The lower bound is here for the opposite mistake, a sleep that returns
    immediately, which would pass the upper bound easily.
    """
    comptime iterations = 40
    comptime request_ns = 200_000

    var start = monotonic()
    for _ in range(iterations):
        sleep(Float64(request_ns) / 1_000_000_000.0)
    var elapsed = monotonic() - start

    assert_true(
        elapsed >= iterations * request_ns,
        "sleeps returned sooner than they were asked to",
    )
    assert_true(
        elapsed < 300_000_000,
        "sleeps took long enough to suggest millisecond granularity",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
