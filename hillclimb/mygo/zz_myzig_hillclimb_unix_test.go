//go:build !windows && myzig_hillclimb

// Copied into mygo's ui package by myzig's hill-climb tool: the process's
// CPU time on macOS and Linux, every thread's, and a monotonic clock.
package ui

import (
	"syscall"
	"time"
)

var hcEpoch = time.Now()

// hcNow is the time since the test started, on the monotonic clock.
func hcNow() time.Duration { return time.Since(hcEpoch) }

func cpuNow() time.Duration {
	var ru syscall.Rusage
	syscall.Getrusage(syscall.RUSAGE_SELF, &ru)
	return time.Duration(ru.Utime.Nano() + ru.Stime.Nano())
}
