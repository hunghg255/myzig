// mygo-blank opens one hidden window on about:blank and quits after nine
// seconds: mygo's side of measure.ps1.
package main

import (
	"log"
	"os"
	"time"

	"github.com/egoist/mygo"
)

func main() {
	mygo.App.WhenReady(func() {
		win := mygo.NewWindow(mygo.WindowOptions{Width: 480, Height: 320, Hidden: true})
		if err := win.Page().LoadURL("about:blank"); err != nil {
			log.Fatal(err)
		}
	})
	go func() { time.Sleep(9 * time.Second); os.Exit(0) }()
	if err := mygo.App.Run(); err != nil {
		log.Fatal(err)
	}
}
