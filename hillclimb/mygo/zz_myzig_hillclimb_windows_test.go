//go:build windows && myzig_hillclimb

// Copied into mygo's ui package by myzig's hill-climb tool: the process's
// CPU time on Windows, every thread's, and a clock finer than time.Now's
// there (which moves in steps of about a millisecond).
package ui

import (
	"syscall"
	"time"
	"unsafe"
)

var (
	hcKernel32 = syscall.NewLazyDLL("kernel32.dll")
	hcQPC      = hcKernel32.NewProc("QueryPerformanceCounter")
	hcQPF      = hcKernel32.NewProc("QueryPerformanceFrequency")
	hcFreq     = func() int64 {
		var f int64
		hcQPF.Call(uintptr(unsafe.Pointer(&f)))
		return f
	}()
)

// hcNow reads the performance counter.
func hcNow() time.Duration {
	var c int64
	hcQPC.Call(uintptr(unsafe.Pointer(&c)))
	return time.Duration(c/hcFreq*int64(time.Second) + c%hcFreq*int64(time.Second)/hcFreq)
}

func cpuNow() time.Duration {
	var created, exited, kernel, user syscall.Filetime
	p, _ := syscall.GetCurrentProcess()
	syscall.GetProcessTimes(p, &created, &exited, &kernel, &user)
	ticks := func(t syscall.Filetime) int64 { return int64(t.HighDateTime)<<32 | int64(t.LowDateTime) }
	return time.Duration((ticks(kernel) + ticks(user)) * 100)
}
