//go:build darwin && myzig_hillclimb

// Copied into mygo's ui package by myzig's hill-climb tool: on macOS the
// scenes are drawn by mygo's Metal renderer, offscreen.
package ui

import (
	"time"

	"github.com/egoist/mygo/internal/gpu/metal"
	"github.com/egoist/mygo/internal/scene"
)

type hcMetal struct{ off *metal.Offscreen }

func hcNewRenderer(w, h int) (hcRenderer, error) {
	off, err := metal.NewOffscreen(w, h)
	if err != nil {
		return nil, err
	}
	return hcMetal{off}, nil
}

func (m hcMetal) frame(s *scene.Scene) (time.Duration, time.Duration, error) { return m.off.Frame(s) }
func (m hcMetal) release()                                                   { m.off.Release() }
