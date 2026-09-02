//===----------------------------------------------------------------------===//
// Copyright (c) 2026, Modular Inc. All rights reserved.
//
// Licensed under the Apache License v2.0 with LLVM Exceptions:
// https://llvm.org/LICENSE.txt
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

#include "AsyncRT/Support/Semaphore.h"
#include "llvm/Support/ErrorHandling.h"
#include <cassert>

#if defined(__APPLE__)
#include <dispatch/dispatch.h>
#elif defined(_WIN32)
#include <chrono>
#include <cstddef>
#include <semaphore>
#else
#include <cassert>
#include <cerrno>
#include <semaphore.h>
#endif

using namespace M::AsyncRT;

/// This class provides the implementation for the Semaphore object. Because we
/// have so many different implementation details, we encapsulate the
/// platform-specific details into this pImpl class.
class Semaphore::Impl {
public:
  /// Manage semaphore lifetime. In cases where this wraps other APIs, this
  /// should be used to (for example) call sem_destroy.
  Impl(ssize_t initialValue);
  ~Impl();

  /// Increment the semaphore.
  void post();

  bool wait();
  bool wait(int64_t timeoutNS);

private:
#if defined(__APPLE__)
  dispatch_semaphore_t sema;
#elif defined(_WIN32)
  std::counting_semaphore<> sema;
#else
  sem_t sema;
#endif
};

Semaphore::Semaphore(Semaphore &&other) = default;

//===----------------------------------------------------------------------===//
// Semaphore::Impl function implementations
//===----------------------------------------------------------------------===//

#if defined(__APPLE__)
//===----------------------------------------------------------------------===//
// Semaphore::Impl for Apple platforms
//===----------------------------------------------------------------------===//

Semaphore::Impl::Impl(ssize_t initialValue)
    : sema(dispatch_semaphore_create(initialValue)) {
  assert(initialValue >= 0 && "semaphore initial value cannot be negative");
}
Semaphore::Impl::~Impl() { dispatch_release(sema); }
void Semaphore::Impl::post() { dispatch_semaphore_signal(sema); }

bool Semaphore::Impl::wait() {
  return 0 != dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
}

bool Semaphore::Impl::wait(int64_t timeoutNS) {
  dispatch_time_t timeout =
      dispatch_time(DISPATCH_TIME_NOW, /*nsecToAdd*/ timeoutNS);
  return 0 != dispatch_semaphore_wait(sema, timeout);
}

#elif defined(_WIN32)
//===----------------------------------------------------------------------===//
// Semaphore::Impl for Windows
//===----------------------------------------------------------------------===//

// This is the standard library's semaphore rather than a Win32 one, and that is
// worth a word, because the obvious Windows answer is CreateSemaphoreW.
//
// CreateSemaphoreW wants a maximum count when the semaphore is created, and
// this interface has no maximum to give it. We would have to invent one, and
// then hope post() never reaches it, in a post() that returns void and so has
// nowhere to report that it did. It also hands back a HANDLE, which is a kernel
// object: a syscall on every wait and every post even when nothing is
// contended, and one more thing the destructor has to close. Neither of those
// is a disaster, but neither is paying for anything we want.
//
// std::counting_semaphore is the same shape as this interface, down to the
// timed acquire, and on Windows it is an atomic in the uncontended case that
// only enters the kernel, by way of WaitOnAddress, when a thread actually has
// to sleep. That is the lighter weight primitive the two arms either side of
// this one already get from GCD and from futex-backed sem_t.
//
// The reason this is not simply used on all three platforms, deleting the
// other two arms, is that the other two arms are upstream's and they work.
// Every upstream line we rewrite is a line to merge again on the next bump.

namespace {
/// Checked here rather than in the constructor body because the member is
/// constructed before the body runs, and a negative count is a precondition
/// violation for std::counting_semaphore itself. An assert in the body would
/// fire after the thing it is meant to be guarding.
ptrdiff_t checkedInitialValue(ssize_t initialValue) {
  assert(initialValue >= 0 && "semaphore initial value cannot be negative");
  return static_cast<ptrdiff_t>(initialValue);
}
} // namespace

Semaphore::Impl::Impl(ssize_t initialValue)
    : sema(checkedInitialValue(initialValue)) {}

Semaphore::Impl::~Impl() = default;

void Semaphore::Impl::post() { sema.release(); }

bool Semaphore::Impl::wait() {
  sema.acquire();
  // False means acquired. That reads backwards, but it is what the two arms
  // either side of this one return, where a true is an error or a timeout.
  // acquire() has no failure mode that returns, so this one is always false.
  return false;
}

bool Semaphore::Impl::wait(int64_t timeoutNS) {
  // True on timeout, false on acquire, matching the other two arms.
  //
  // try_acquire_for, unlike the plain try_acquire, does not fail spuriously:
  // it retries internally until it either takes the count or the duration runs
  // out. So there is no deadline loop to write here, and no rounding of
  // nanoseconds into whatever unit the platform call wanted, which is where a
  // hand written version of this would be most likely to wake up early.
  return !sema.try_acquire_for(std::chrono::nanoseconds(timeoutNS));
}

#else
//===----------------------------------------------------------------------===//
// Semaphore::Impl for POSIX platforms with sem_timedwait
//===----------------------------------------------------------------------===//

Semaphore::Impl::Impl(ssize_t initialValue) {
  assert(initialValue >= 0 && "semaphore initial value cannot be negative");
  if (-1 == sem_init(&sema, 0, initialValue))
    llvm::report_fatal_error("Unable to initialize an unnamed semaphore.");
}

Semaphore::Impl::~Impl() {
  [[maybe_unused]] int rc = sem_destroy(&sema);
  assert(rc == 0 && "Unable to destroy the unnamed semaphore.");
}

void Semaphore::Impl::post() { sem_post(&sema); }

bool Semaphore::Impl::wait() {
  int rc;
  // If we have no timeout, then we just have check for having been interrupted
  // by a signal handler.
  while ((rc = sem_wait(&sema)) == -1 && errno == EINTR)
    continue;

  // If sem_wait returned 0 then we're good, we acquired the semaphore.
  // Otherwise, we hit an error and were unable to acquire the semaphore.
  return rc != 0;
}

bool Semaphore::Impl::wait(int64_t timeoutNS) {
  // Get the current time - the timeout on sem_timedwait is an absolute timeout
  // since the epoch.
  struct timespec ts;
  if (-1 == clock_gettime(CLOCK_REALTIME, &ts))
    llvm::report_fatal_error("Unable to call clock_gettime");

  ts.tv_nsec += timeoutNS;
  // The semaphore may be interrupted by a signal handler, so check for this
  // case and continue if that is what happens.
  int rc;
  while ((rc = sem_timedwait(&sema, &ts)) == -1 && errno == EINTR)
    continue;

  // Semaphore successfully decremented, return no error.
  if (rc == 0)
    return false;

  // Timeout occurred.
  if (rc == -1 && errno == ETIMEDOUT)
    return true;

  llvm::report_fatal_error(
      "sem_timedwait failed for a reason other than EINTR or ETIMEDOUT.");
}
#endif

//===----------------------------------------------------------------------===//
// Semaphore function implementations (just forward to Semaphore::Impl)
//===----------------------------------------------------------------------===//

Semaphore::Semaphore(ssize_t initialValue)
    : impl(std::make_unique<Semaphore::Impl>(initialValue)) {}

// Empty destructor needed here so we can forward declare Semaphore::Impl into
// the header.
Semaphore::~Semaphore() = default;

void Semaphore::post() { impl->post(); }

bool Semaphore::wait() { return impl->wait(); }

bool Semaphore::wait(int64_t timeoutNS) { return impl->wait(timeoutNS); }
