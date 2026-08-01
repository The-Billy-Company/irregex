//go:build cgo

package irregex

import (
	"sync"
	"testing"
	"unsafe"
)

// The C handle is single-threaded: two goroutines running finds through one
// would corrupt a match rather than race a counter, and the race detector would
// not see it because the corruption happens inside C. So the pool has to be
// proven directly.
//
// Every worker takes a handle and holds it until all of them have one, which
// forces the pool to grow instead of recycling. If two workers ever see the same
// address, the pool is broken.
func TestPoolLendsEachHandleOnce(t *testing.T) {
	re := MustCompile(`\w+`)
	const workers = 64
	var (
		mu       sync.Mutex
		seen     = make(map[unsafe.Pointer]int, workers)
		acquired sync.WaitGroup
		done     sync.WaitGroup
	)
	release := make(chan struct{})
	acquired.Add(workers)
	done.Add(workers)
	for range workers {
		go func() {
			defer done.Done()
			h := re.acquire()
			mu.Lock()
			seen[unsafe.Pointer(h.ptr)]++
			mu.Unlock()
			acquired.Done()
			<-release
			re.release(h)
		}()
	}
	acquired.Wait()
	mu.Lock()
	distinct := len(seen)
	for ptr, count := range seen {
		if count > 1 {
			t.Errorf("handle %p was lent to %d goroutines at once", ptr, count)
		}
	}
	mu.Unlock()
	if distinct != workers {
		t.Errorf("%d workers held %d distinct handles", workers, distinct)
	}
	close(release)
	done.Wait()

	// And a handle that comes back is reusable, not poisoned: the pool is an
	// optimization, so the next search must still answer.
	if got := re.FindAllString("one two", -1); len(got) != 2 {
		t.Errorf("after the pool round trip, FindAllString = %q", got)
	}
}
