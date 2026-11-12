param(
    [Parameter(Mandatory = $true)][string]$CompletionEvent,
    [Parameter(Mandatory = $true)][int]$MonitorProcessId
)

# The monitor keeps this event alive until authentication finishes.
try { $completion = [System.Threading.EventWaitHandle]::OpenExisting($CompletionEvent) }
catch { exit }
if ($completion.WaitOne(0)) { $completion.Dispose(); exit }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Teams Monitor - Microsoft sign-in'
$form.ClientSize = New-Object System.Drawing.Size(480, 185)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false

$label = New-Object System.Windows.Forms.Label
$label.Location = New-Object System.Drawing.Point(20, 18)
$label.Size = New-Object System.Drawing.Size(440, 65)
$label.Text = "監視画面に認証コードが表示されたら、下のボタンを押してください。`r`nブラウザーでコードを入力し、会社のアカウントでサインインします。"
$form.Controls.Add($label)

$button = New-Object System.Windows.Forms.Button
$button.Location = New-Object System.Drawing.Point(70, 90)
$button.Size = New-Object System.Drawing.Size(340, 40)
$button.Text = 'ブラウザーで認証する'
$button.Add_Click({
    try { Start-Process -FilePath 'https://microsoft.com/devicelogin' -ErrorAction Stop | Out-Null }
    catch { [System.Windows.Forms.MessageBox]::Show('ブラウザーを開けませんでした。https://microsoft.com/devicelogin を開いてください。', 'Teams Monitor') | Out-Null }
})
$form.Controls.Add($button)

$link = New-Object System.Windows.Forms.LinkLabel
$link.Location = New-Object System.Drawing.Point(70, 145)
$link.Size = New-Object System.Drawing.Size(340, 25)
$link.Text = 'https://microsoft.com/devicelogin'
$link.Add_LinkClicked({ $button.PerformClick() })
$form.Controls.Add($link)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 300
$timer.Add_Tick({
    $monitorRunning = $true
    try { $null = [System.Diagnostics.Process]::GetProcessById($MonitorProcessId) }
    catch { $monitorRunning = $false }
    if ($completion.WaitOne(0) -or -not $monitorRunning) { $form.Close() }
})
try {
    if (-not $completion.WaitOne(0)) {
        $timer.Start()
        [void]$form.ShowDialog()
    }
}
finally {
    $timer.Stop()
    $timer.Dispose()
    $form.Dispose()
    $completion.Dispose()
}
