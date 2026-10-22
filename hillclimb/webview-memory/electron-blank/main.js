// One hidden window on about:blank, quit after nine seconds: Electron's
// side of measure.ps1.
const { app, BrowserWindow } = require('electron')

app.whenReady().then(() => {
  const win = new BrowserWindow({ width: 480, height: 320, show: false })
  win.loadURL('about:blank')
  setTimeout(() => app.quit(), 9000)
})
