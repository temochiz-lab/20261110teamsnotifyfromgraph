Add-Type -AssemblyName System.Media

while ($true) {
    [System.Media.SystemSounds]::Asterisk.Play()
    Start-Sleep -Seconds 30
}

