//go:build !darwin && myzig_hillclimb

// Copied into mygo's ui package by myzig's hill-climb tool: where there is
// no Metal, the scenes are drawn by mygo's CPU renderer into memory, whole
// every frame (as myzig's CPU renderer draws them), not only what changed.
package ui

import (
	"time"

	"github.com/egoist/mygo/internal/raster"
	"github.com/egoist/mygo/internal/scene"
)

type hcRaster struct{ r *raster.Renderer }

func hcNewRenderer(w, h int) (hcRenderer, error) { return hcRaster{&raster.Renderer{}}, nil }

func (c hcRaster) frame(s *scene.Scene) (time.Duration, time.Duration, error) {
	c.r.Invalidate()
	t0 := hcNow()
	c.r.Render(s)
	return hcNow() - t0, 0, nil
}

func (c hcRaster) release() { c.r.Release() }
