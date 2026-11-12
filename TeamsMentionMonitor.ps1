# TeamsMentionMonitor v7
# Detect:
# 1) unread incoming 1:1 messages at startup
# 2) new incoming 1:1 messages after startup
# 3) new mentions of the current user after startup (1:1 + group chat)
#
# IMPORTANT:
# - No $expand=mentions is used. The previous version incorrectly used it.
# - Startup existing mentions are registered as baseline and do NOT alert.
# - Mention diagnostics are printed so we can see exactly what Graph returns.
# - ASCII-only source.

param(
    [int]$IntervalSeconds = 30
)

if ($IntervalSeconds -lt 1) {
    throw "IntervalSeconds must be 1 or greater."
}

function Read-MonitorSettings {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Settings file not found: $Path"
    }

    $settings = @{}
    $lineNumber = 0
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop)) {
        $lineNumber++
        $text = $line.Trim()
        if (-not $text -or $text.StartsWith('#')) { continue }
        if ($text -notmatch '^(topicname|pcname)\s*=\s*(.+)$') {
            throw "Invalid setting at line ${lineNumber}: $Path"
        }
        $key = $Matches[1].ToLowerInvariant()
        $value = $Matches[2].Trim()
        if (-not $value -or $settings.ContainsKey($key)) {
            throw "Empty or duplicate setting '${key}': $Path"
        }
        $settings[$key] = $value
    }

    foreach ($key in @('topicname', 'pcname')) {
        if (-not $settings.ContainsKey($key)) { throw "Missing setting '${key}': $Path" }
    }
    if ($settings['topicname'] -notmatch '^[A-Za-z0-9_-]{1,64}$') {
        throw "topicname must be 1-64 letters, digits, underscores or hyphens: $Path"
    }
    return $settings
}

$MonitorSettings = Read-MonitorSettings -Path (Join-Path $PSScriptRoot 'setting.txt')
$NtfyUri = 'https://ntfy.sh/' + $MonitorSettings['topicname']
$PcName = $MonitorSettings['pcname']

function Get-LogTimestamp {
    return (Get-Date).ToString("yyyy/MM/dd HH:mm:ss")
}

function Write-PollStart {
    param([string]$Message)
    Write-Host ("[" + (Get-LogTimestamp) + "] " + $Message) -ForegroundColor Blue
}

function Write-Hit {
    param([string]$Message)
    Write-Host ("[" + (Get-LogTimestamp) + "] " + $Message) -ForegroundColor Yellow
}
# Send one startup notification before Graph authentication.
try {
    $StartupMessage = "Start " + (Get-LogTimestamp) + " [$PcName]"
    Invoke-RestMethod -Method Post `
        -Uri $NtfyUri `
        -ContentType "text/plain; charset=utf-8" `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($StartupMessage)) `
        -TimeoutSec 10 -ErrorAction Stop | Out-Null
    Write-Host "ntfy startup notification sent: $StartupMessage"
}
catch {
    Write-Warning "ntfy startup notification failed: $($_.Exception.Message)"
}

Import-Module Microsoft.Graph.Authentication

$SoundFile = Join-Path $PSScriptRoot "notice.wav"

# Successful notifications are remembered per chat/message for this run.
$NotifiedMessages = @{}

function Send-ReceivedNotification {
    try {
        $Message = "received " + (Get-LogTimestamp) + " [$PcName]"
        Invoke-RestMethod -Headers @{ Priority = "5" } -Method Post `
            -Uri $NtfyUri `
            -ContentType "text/plain; charset=utf-8" `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($Message)) `
            -TimeoutSec 10 -ErrorAction Stop | Out-Null
        Write-Host "ntfy mention notification sent: $Message"
        return $true
    }
    catch {
        Write-Warning "ntfy mention notification failed: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-MessageAlert {
    param(
        [Parameter(Mandatory = $true)][string]$ChatId,
        [Parameter(Mandatory = $true)][object[]]$Messages
    )

    if (-not $NotifiedMessages.ContainsKey($ChatId)) {
        $NotifiedMessages[$ChatId] = @{}
    }
    $notified = $NotifiedMessages[$ChatId]

    foreach ($AlertMessage in $Messages) {
        $id = [string]$AlertMessage.id
        if (-not $id -or $notified.ContainsKey($id)) { continue }

        # Record successful sends only; later unread polls can retry failures.
        if (Send-ReceivedNotification) {
            $notified[$id] = $true
        }
    }

    # Keep the existing unread sound reminders even after ntfy was sent.
    Play-NotifySound
}

function Play-NotifySound {
    if (-not (Test-Path $SoundFile)) {
        Write-Host "Sound file not found: $SoundFile"
        return
    }

    try {
        $player = New-Object System.Media.SoundPlayer
        $player.SoundLocation = $SoundFile
        $player.Load()
        Write-Host ">>> SOUND ALERT <<<"
        $player.PlaySync()
        Write-Host "Sound OK"
    }
    catch {
        Write-Host "Sound error: $($_.Exception.Message)"
    }
}

function Get-GraphErrorText {
    param($ErrorRecord)

    $text = $ErrorRecord.Exception.Message

    try {
        if ($ErrorRecord.ErrorDetails.Message) {
            $text = $ErrorRecord.ErrorDetails.Message
        }
    }
    catch {}

    return $text
}

$script:GraphReconnectAfter = [datetime]::MinValue

function Connect-MonitorGraph {
    param([string]$TenantId)

    $parameters = @{
        Scopes = @('User.Read', 'Chat.Read')
        ContextScope = 'CurrentUser'
        UseDeviceCode = $true
        NoWelcome = $true
        ErrorAction = 'Stop'
    }
    if ($TenantId) { $parameters['TenantId'] = $TenantId }

    $completion = $null
    try {
        # A separate UI stays responsive while Connect-MgGraph waits for sign-in.
        # It does not depend on the SDK emitting device-code text into the pipeline.
        try {
            $eventName = 'Local\TeamsMonitorSignIn-' + [guid]::NewGuid().ToString('N')
            $completion = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $eventName)
            $windowPath = Join-Path $PSScriptRoot 'GraphSignInWindow.ps1'
            $arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + $windowPath + '" -CompletionEvent ' + $eventName + ' -MonitorProcessId ' + $PID
            Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Warning 'Could not show the sign-in button. Open https://microsoft.com/devicelogin manually if a code is displayed.'
        }

        $browserOpened = $false
        Connect-MgGraph @parameters | ForEach-Object {
            $instructions = [string]$_
            Write-Host $instructions
            if (-not $browserOpened -and $instructions -match 'https://(?:www\.)?microsoft\.com/devicelogin\b') {
                $browserOpened = $true
                try { Start-Process -FilePath 'https://microsoft.com/devicelogin' -ErrorAction Stop | Out-Null }
                catch { Write-Warning 'Click the sign-in button or open https://microsoft.com/devicelogin manually.' }
            }
        }
    }
    finally {
        if ($null -ne $completion) {
            [void]$completion.Set()
            $completion.Dispose()
        }
    }
}

function Test-GraphAuthenticationError {
    param($ErrorRecord)

    $details = [string]$ErrorRecord.Exception.ToString() + " " + (Get-GraphErrorText $ErrorRecord)
    if ($details -match 'InteractiveBrowserCredential|DeviceCodeCredential|AuthenticationFailedException|MsalUiRequiredException|interaction_required|invalid_grant|InvalidAuthenticationToken') {
        return $true
    }
    try {
        if ([int]$ErrorRecord.Exception.Response.StatusCode -eq 401) { return $true }
    }
    catch {}
    return $false
}

function Invoke-MonitorGraphRequest {
    param([Parameter(Mandatory = $true)][string]$Uri)

    try {
        return (Invoke-MgGraphRequest -Method GET -Uri $Uri -ErrorAction Stop)
    }
    catch {
        if (-not (Test-GraphAuthenticationError $_)) { throw }
        if ((Get-Date) -lt $script:GraphReconnectAfter) { throw }

        # Limit interactive sign-in attempts if the user cancels or policy blocks access.
        $script:GraphReconnectAfter = (Get-Date).AddMinutes(5)
        Write-Warning ("[" + (Get-LogTimestamp) + "] Graph authentication failed. Please sign in again; monitoring is paused.")
        $context = Get-MgContext -ErrorAction SilentlyContinue


        if ($context) { Disconnect-MgGraph -ErrorAction Stop | Out-Null }
        Write-Host "Reconnecting to Graph. If a code is shown, open the displayed Microsoft URL and enter that code."
        Connect-MonitorGraph -TenantId $context.TenantId

        # Preserve existing unread, mention and notification state for the same user only.
        if ($script:MyId) {
            $currentUser = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/me' -ErrorAction Stop
            if ([string]$currentUser.id -ne $script:MyId) {
                Disconnect-MgGraph -ErrorAction Stop | Out-Null
                throw 'A different Graph account was selected. Sign in with the original monitoring account.'
            }
        }
        $result = Invoke-MgGraphRequest -Method GET -Uri $Uri -ErrorAction Stop
        Write-Host ("[" + (Get-LogTimestamp) + "] Graph authentication restored. Monitoring resumed.")
        return $result
    }
}

function Get-GraphMessages {
    param(
        [string]$ChatId,
        [int]$Top = 50
    )

    $encodedChatId = [System.Uri]::EscapeDataString($ChatId)
    $uri = "https://graph.microsoft.com/v1.0/chats/$encodedChatId/messages?`$top=$Top"

    try {
        $result = Invoke-MonitorGraphRequest -Uri $uri
        return @($result.value)
    }
    catch {
        Write-Host "Message API error: $(Get-GraphErrorText $_)"
        return @()
    }
}

function Get-SenderInfo {
    param($Message)

    $senderId = $null
    $senderName = "unknown"
    $senderType = "unknown"

    try {
        if ($Message.from.user.id) {
            $senderId = [string]$Message.from.user.id
            $senderType = "user"
        }
        elseif ($Message.from.application.id) {
            $senderId = [string]$Message.from.application.id
            $senderType = "application"
        }
    }
    catch {}

    try {
        if ($Message.from.user.displayName) {
            $senderName = [string]$Message.from.user.displayName
        }
        elseif ($Message.from.application.displayName) {
            $senderName = [string]$Message.from.application.displayName
        }
    }
    catch {}

    return @{
        Id = $senderId
        Name = $senderName
        Type = $senderType
    }
}

function Get-MentionInfo {
    param(
        $Message,
        [string]$MyId
    )

    $result = @{
        HasMentions = $false
        MentionCount = 0
        MentionsCurrentUser = $false
        MentionDetails = @()
    }

    try {
        if ($null -eq $Message.mentions) {
            return $result
        }

        $mentions = @($Message.mentions)
        $result.MentionCount = $mentions.Count

        if ($mentions.Count -gt 0) {
            $result.HasMentions = $true
        }

        foreach ($Mention in $mentions) {

            $mentionedId = $null
            $mentionedName = "unknown"

            try {
                if ($Mention.mentioned.user.id) {
                    $mentionedId = [string]$Mention.mentioned.user.id
                }
            }
            catch {}

            try {
                if ($Mention.mentioned.user.displayName) {
                    $mentionedName = [string]$Mention.mentioned.user.displayName
                }
            }
            catch {}

            $result.MentionDetails += @{
                Id = $mentionedId
                Name = $mentionedName
            }

            if ($mentionedId -and $mentionedId -eq $MyId) {
                $result.MentionsCurrentUser = $true
            }
        }
    }
    catch {
        Write-Host "Mention parsing error: $($_.Exception.Message)"
    }

    return $result
}

Write-Host "=========================================="
Write-Host " TEAMS MONITOR v7"
Write-Host "=========================================="
Write-Host "Interval: $IntervalSeconds seconds"
Write-Host "Startup: unread 1:1 + 1:1/group mention baseline"
Write-Host "Runtime: unread 1:1/group mentions repeat until read"
Write-Host "Mention API: NO expand=mentions"
Write-Host ""

Write-Host "Testing sound..."
Play-NotifySound
Write-Host ""

try {
    Write-Host "Connecting to Graph using the saved sign-in (device code only when needed)."
    Write-Host "If a code is shown below, click the button in the sign-in window to open your browser."
    Connect-MonitorGraph
    Write-Host "Graph sign-in completed. Loading chats..."
}
catch {
    Write-Host "Graph connection failed."
    Write-Host (Get-GraphErrorText $_)
    exit
}

try {
    $Me = Invoke-MonitorGraphRequest -Uri "https://graph.microsoft.com/v1.0/me"
    $MyId = [string]$Me.id
    $MyName = [string]$Me.displayName
}
catch {
    Write-Host "Failed to get current user."
    Write-Host (Get-GraphErrorText $_)
    exit
}

Write-Host "My name: $MyName"
Write-Host "My ID  : $MyId"
Write-Host ""

try {
    $ChatsResult = Invoke-MonitorGraphRequest -Uri "https://graph.microsoft.com/v1.0/me/chats?`$top=50"
    $Chats = @($ChatsResult.value)
}
catch {
    Write-Host "Failed to get chats."
    Write-Host (Get-GraphErrorText $_)
    exit
}

$OneOnOneChats = @(
    $Chats | Where-Object {
        [string]$_.chatType -eq "oneOnOne"
    }
)

$GroupChats = @(
    $Chats | Where-Object {
        [string]$_.chatType -eq "group"
    }
)

$ChatState = @{}
$MentionBaseline = @{}

Write-Host "Chats found     : $($Chats.Count)"
Write-Host "1:1 chats found : $($OneOnOneChats.Count)"
Write-Host "Group chats     : $($GroupChats.Count)"
Write-Host ""

# ------------------------------------------------------------
# STARTUP
# ------------------------------------------------------------
Write-Host "=========================================="
Write-Host " STARTUP CHECK"
Write-Host "=========================================="

foreach ($Chat in $OneOnOneChats) {

    $ChatId = [string]$Chat.id
    $LastRead = $null

    try {
        $LastRead = $Chat.viewpoint.lastMessageReadDateTime
    }
    catch {}

    Write-Host ""
    Write-Host "[1:1] $ChatId"

    if ($LastRead) {
        if ($LastRead) {
        try {
            $LastReadDisplay = ([datetimeoffset]$LastRead).ToLocalTime().ToString("yyyy/MM/dd HH:mm:ss")
        }
        catch {
            $LastReadDisplay = [string]$LastRead
        }
    }
    else {
        $LastReadDisplay = "none"
    }

    Write-Host ("  Last read: " + $LastReadDisplay)
    }
    else {
        Write-Host "Last read: unavailable"
    }

    $Messages = @(Get-GraphMessages -ChatId $ChatId -Top 50)
    Write-Host ("[" + (Get-LogTimestamp) + "] " + "Messages: $($Messages.Count)")

    $SeenIds = @{}
    $UnreadCount = 0
    $MentionCount = 0

    foreach ($Message in $Messages) {

        $MessageId = [string]$Message.id

        if ($MessageId) {
            $SeenIds[$MessageId] = $true
        }

        $Sender = Get-SenderInfo -Message $Message
        $Created = $null

        try {
            if ($Message.createdDateTime) {
                $Created = [DateTimeOffset]$Message.createdDateTime
            }
        }
        catch {}

        # ----------------------------------------
        # Mention diagnostics.
        # Existing mentions are baseline only.
        # ----------------------------------------
        $MentionInfo = Get-MentionInfo -Message $Message -MyId $MyId

        if ($MentionInfo.HasMentions) {

            $MentionCount++

            if (-not $MentionBaseline.ContainsKey($MessageId)) {
                $MentionBaseline[$MessageId] = $true
            }

            Write-Host ""
            Write-Host "---------- MENTION BASELINE ----------"
            Write-Host "Message ID : $MessageId"
            Write-Host "Created    : $Created"
            Write-Host "Sender     : $($Sender.Name)"
            Write-Host ("[" + (Get-LogTimestamp) + "] " + "Mention #  : $($MentionInfo.MentionCount)")

            foreach ($Detail in $MentionInfo.MentionDetails) {
                Write-Host ("[" + (Get-LogTimestamp) + "] " + "Mentioned  : $($Detail.Name)")
                Write-Host ("[" + (Get-LogTimestamp) + "] " + "Mention ID : $($Detail.Id)")

                if ($Detail.Id -eq $MyId) {
                    Write-Host ("[" + (Get-LogTimestamp) + "] " + "MATCH      : CURRENT USER")
                }
                else {
                    Write-Host ("[" + (Get-LogTimestamp) + "] " + "MATCH      : no")
                }
            }

            Write-Host "Action     : no alert (startup baseline)"
            Write-Host "--------------------------------------"
        }

        # ----------------------------------------
        # Startup unread 1:1.
        # ----------------------------------------
        $IsUnread = $false

        if ($LastRead -and $Created) {
            try {
                $LastReadDto = [DateTimeOffset]$LastRead

                if (
                    $Created -gt $LastReadDto -and
                    $Sender.Id -and
                    $Sender.Id -ne $MyId
                ) {
                    $IsUnread = $true
                }
            }
            catch {}
        }

        if ($IsUnread) {

            $UnreadCount++

            Write-Host ""
            Write-Host ("[" + (Get-LogTimestamp) + "] " + "---------- UNREAD 1:1 FOUND ----------")
            Write-Host "Message ID : $MessageId"
            Write-Host "Created    : $Created"
            Write-Host "Sender     : $($Sender.Name)"
            Write-Host "Sender ID  : $($Sender.Id)"
            Write-Host "Last read  : $LastRead"
            Write-Host "---------------------------------------"

            Invoke-MessageAlert -ChatId $ChatId -Messages @($Message)
        }
    }

    $ChatState[$ChatId] = @{
        SeenIds = $SeenIds
    }

    Write-Host "Startup unread   : $UnreadCount"
    Write-Host "Mention messages : $MentionCount"
}

# ------------------------------------------------------------
# STARTUP GROUP CHAT MENTION BASELINE
# ------------------------------------------------------------
Write-Host ""
Write-Host "=========================================="
Write-Host " GROUP CHAT MENTION BASELINE"
Write-Host "=========================================="

foreach ($Chat in $GroupChats) {

    $ChatId = [string]$Chat.id
    Write-Host ""
    Write-Host ("[" + (Get-LogTimestamp) + "] [GROUP] $ChatId")

    $Messages = @(Get-GraphMessages -ChatId $ChatId -Top 50)
    Write-Host ("[" + (Get-LogTimestamp) + "] Messages: $($Messages.Count)")

    $GroupMentionCount = 0

    foreach ($Message in $Messages) {

        $MessageId = [string]$Message.id
        if (-not $MessageId) {
            continue
        }

        $MentionInfo = Get-MentionInfo -Message $Message -MyId $MyId

        if ($MentionInfo.HasMentions) {
            $GroupMentionCount++
            $MentionBaseline[$MessageId] = $true

            Write-Host ""
            Write-Host "---------- GROUP MENTION BASELINE ----------"
            Write-Host "Message ID : $MessageId"
            Write-Host "Created    : $($Message.createdDateTime)"

            $Sender = Get-SenderInfo -Message $Message
            Write-Host "Sender     : $($Sender.Name)"
            Write-Host ("[" + (Get-LogTimestamp) + "] " + "Mention #  : $($MentionInfo.MentionCount)")

            foreach ($Detail in $MentionInfo.MentionDetails) {
                Write-Host ("[" + (Get-LogTimestamp) + "] " + "Mentioned  : $($Detail.Name)")
                Write-Host ("[" + (Get-LogTimestamp) + "] " + "Mention ID : $($Detail.Id)")

                if ($Detail.Id -eq $MyId) {
                    Write-Host ("[" + (Get-LogTimestamp) + "] " + "MATCH      : CURRENT USER")
                }
                else {
                    Write-Host ("[" + (Get-LogTimestamp) + "] " + "MATCH      : no")
                }
            }

            Write-Host "Action     : no alert (startup baseline)"
            Write-Host "--------------------------------------------"
        }
    }

    Write-Host "Group mention messages : $GroupMentionCount"
}

Write-Host ""
Write-Host "=========================================="
Write-Host " MONITORING STARTED"
Write-Host "=========================================="
Write-Host "Existing mentions are baseline only."
Write-Host "New mentions in 1:1/group chats after startup will alert."
Write-Host ("[" + (Get-LogTimestamp) + "] " + "Unread incoming 1:1 messages alert every poll until read.")
Write-Host "Press Ctrl+C to stop."
Write-Host ""

while ($true) {

    Write-PollStart "========== POLLING START =========="

    Write-Host ""
    Write-Host "[$(Get-Date -Format 'yyyy/MM/dd HH:mm:ss')] checking..."

    try {
        $ChatsResult = Invoke-MonitorGraphRequest -Uri "https://graph.microsoft.com/v1.0/me/chats?`$top=50"
        $Chats = @($ChatsResult.value)
    }
    catch {
        Write-Host "Chat API error: $(Get-GraphErrorText $_)"
        Start-Sleep -Seconds $IntervalSeconds
        continue
    }

    $OneOnOneChats = @(
        $Chats | Where-Object {
            [string]$_.chatType -eq "oneOnOne"
        }
    )

    $GroupChats = @(
        $Chats | Where-Object {
            [string]$_.chatType -eq "group"
        }
    )

    Write-Host "1:1 chats: $($OneOnOneChats.Count)"
    Write-Host "Group chats: $($GroupChats.Count)"

    foreach ($Chat in $OneOnOneChats) {

        $ChatId = [string]$Chat.id

        if (-not $ChatState.ContainsKey($ChatId)) {
            $ChatState[$ChatId] = @{
                SeenIds = @{}
            }
        }

        $State = $ChatState[$ChatId]
        $Messages = @(Get-GraphMessages -ChatId $ChatId -Top 50)

        Write-Host ("[" + (Get-LogTimestamp) + "] " + "[1:1] Messages: $($Messages.Count)")

        # Get the current Teams read position for this chat.
        $LastRead = $null
        try {
            $LastRead = $Chat.viewpoint.lastMessageReadDateTime
        }
        catch {}

        $UnreadIncoming = @()

        if ($LastRead) {
            Write-Host "Last read: $LastRead"
        }
        else {
            Write-Host "Last read: unavailable"
        }

        foreach ($Message in $Messages) {

            $MessageId = [string]$Message.id

            if (-not $MessageId) {
                continue
            }

            $Sender = Get-SenderInfo -Message $Message

            # ----------------------------------------
            # UNREAD 1:1 CHECK
            #
            # This is intentionally NOT a "new message" check.
            # If the message remains unread, it stays in this list
            # and the alarm sounds again on every polling cycle.
            # Once Teams marks it as read, it drops out and the
            # repeated alarm stops.
            # ----------------------------------------
            $MessageCreated = $null

            try {
                if ($Message.createdDateTime) {
                    $MessageCreated = [DateTimeOffset]$Message.createdDateTime
                }
            }
            catch {}

            $IsUnreadIncoming = $false

            if (
                $LastRead -and
                $MessageCreated -and
                $Sender.Id -and
                $Sender.Id -ne $MyId
            ) {
                try {
                    $LastReadDto = [DateTimeOffset]$LastRead

                    if ($MessageCreated -gt $LastReadDto) {
                        $IsUnreadIncoming = $true
                    }
                }
                catch {}
            }

            if ($IsUnreadIncoming) {
                $UnreadIncoming += $Message
            }

            # ----------------------------------------
            # MENTION CHECK
            # Independent of unread status.
            # ----------------------------------------
            $MentionInfo = Get-MentionInfo -Message $Message -MyId $MyId

            if ($MentionInfo.HasMentions) {

                if ($MentionInfo.MentionsCurrentUser) {

                    if (-not $MentionBaseline.ContainsKey($MessageId)) {

                        $MentionBaseline[$MessageId] = $true

                        Write-Host ""
                        Write-Hit ("[" + (Get-LogTimestamp) + "] " + "========== NEW MENTION DETECTED ==========")
                        Write-Host "Message ID : $MessageId"
                        Write-Host "Created    : $($Message.createdDateTime)"
                        Write-Host "Sender     : $($Sender.Name)"
                        Write-Host "Sender ID  : $($Sender.Id)"
                        Write-Host ("[" + (Get-LogTimestamp) + "] " + "Mention #  : $($MentionInfo.MentionCount)")

                        foreach ($Detail in $MentionInfo.MentionDetails) {
                            Write-Host ("[" + (Get-LogTimestamp) + "] " + "Mentioned  : $($Detail.Name)")
                            Write-Host ("[" + (Get-LogTimestamp) + "] " + "Mention ID : $($Detail.Id)")
                        }

                        Write-Host "==========================================="

                        Invoke-MessageAlert -ChatId $ChatId -Messages @($Message)
                    }
                }
            }

            # ----------------------------------------
            # NEW 1:1 MESSAGE BASELINE
            #
            # We keep SeenIds for diagnostics/history, but the
            # alarm condition below is based on Teams read state.
            # ----------------------------------------
            if (-not $State.SeenIds.ContainsKey($MessageId)) {
                $State.SeenIds[$MessageId] = $true

                Write-Host ""
                Write-Host ("[" + (Get-LogTimestamp) + "] " + "---------- NEW MESSAGE SEEN ----------")
                Write-Host "Message ID : $MessageId"
                Write-Host "Created    : $($Message.createdDateTime)"
                Write-Host "Sender     : $($Sender.Name)"
                Write-Host "Sender ID  : $($Sender.Id)"
                Write-Host "--------------------------------------"
            }
        }

        # ----------------------------------------
        # REPEATING UNREAD ALARM
        #
        # One sound per polling cycle, even if multiple
        # unread messages exist in the same chat.
        # ----------------------------------------
        if ($UnreadIncoming.Count -gt 0) {

            Write-Host ""
            Write-Hit ("[" + (Get-LogTimestamp) + "] " + "========== UNREAD 1:1 STILL PRESENT ==========")
            Write-Host ("[" + (Get-LogTimestamp) + "] " + "Unread incoming count: $($UnreadIncoming.Count)")

            foreach ($UnreadMessage in $UnreadIncoming) {
                $UnreadSender = Get-SenderInfo -Message $UnreadMessage

                Write-Host "Unread message ID : $($UnreadMessage.id)"
                Write-Host "Created           : $($UnreadMessage.createdDateTime)"
                Write-Host "Sender            : $($UnreadSender.Name)"
            }

            Write-Host "Action            : SOUND ALERT (repeat every $IntervalSeconds sec until read)"
            Write-Host "==============================================="

            Invoke-MessageAlert -ChatId $ChatId -Messages $UnreadIncoming
        }
        else {
            Write-Host ("[" + (Get-LogTimestamp) + "] " + "Unread incoming 1:1: none")
        }

        if ($State.SeenIds.Count -gt 500) {
            $State.SeenIds = @{}

            foreach ($Message in $Messages) {
                $MessageId = [string]$Message.id

                if ($MessageId) {
                    $State.SeenIds[$MessageId] = $true
                }
            }
        }
    }

    # --------------------------------------------------------
    # GROUP CHAT MENTION CHECK
    #
    # A mention of the current user remains in the snooze state
    # until Teams marks the message as read.
    # One sound is played per polling cycle while unread mentions
    # remain.
    # --------------------------------------------------------
    foreach ($Chat in $GroupChats) {

        $ChatId = [string]$Chat.id
        $Messages = @(Get-GraphMessages -ChatId $ChatId -Top 50)

        Write-Host ("[" + (Get-LogTimestamp) + "] [GROUP] Messages: $($Messages.Count)")

        $UnreadGroupMentions = @()

        foreach ($Message in $Messages) {

            $MessageId = [string]$Message.id

            if (-not $MessageId) {
                continue
            }

            $MentionInfo = Get-MentionInfo -Message $Message -MyId $MyId

            if (-not $MentionInfo.HasMentions -or -not $MentionInfo.MentionsCurrentUser) {
                continue
            }

            # Skip messages that existed when the monitor started.
            # Only mentions first seen after startup are eligible for snooze.
            if (-not $MentionBaseline.ContainsKey($MessageId)) {

                $MentionBaseline[$MessageId] = $true

                $Sender = Get-SenderInfo -Message $Message

                Write-Host ""
                Write-Hit ("[" + (Get-LogTimestamp) + "] " + "========== NEW GROUP MENTION DETECTED ==========")
                Write-Host "Chat ID    : $ChatId"
                Write-Host "Message ID : $MessageId"
                Write-Host "Created    : $($Message.createdDateTime)"
                Write-Host "Sender     : $($Sender.Name)"
                Write-Host "Sender ID  : $($Sender.Id)"

                foreach ($Detail in $MentionInfo.MentionDetails) {
                    Write-Host ("[" + (Get-LogTimestamp) + "] " + "Mentioned  : $($Detail.Name)")
                    Write-Host ("[" + (Get-LogTimestamp) + "] " + "Mention ID : $($Detail.Id)")
                }

                Write-Hit "Action     : SOUND ALERT"
                Write-Host "================================================="

                Invoke-MessageAlert -ChatId $ChatId -Messages @($Message)
            }

            # Graph chat viewpoint indicates whether the current user
            # has read through the message. For group chats, use the
            # chat-level lastMessageReadDateTime as the snooze boundary.
            $LastRead = $Chat.viewpoint.lastMessageReadDateTime
            $Created = $Message.createdDateTime

            if (
                $LastRead -and
                $Created -and
                ([datetimeoffset]$Created -gt [datetimeoffset]$LastRead)
            ) {
                $UnreadGroupMentions += $Message
            }
        }

        if ($UnreadGroupMentions.Count -gt 0) {

            Write-Host ""
            Write-Hit ("[" + (Get-LogTimestamp) + "] " + "========== GROUP MENTION STILL UNREAD ==========")
            Write-Host "Chat ID          : $ChatId"
            Write-Host "Unread mentions  : $($UnreadGroupMentions.Count)"
            Write-Hit "Action           : SOUND ALERT"
            Write-Host "Next check       : $IntervalSeconds sec"
            Write-Host "================================================"

            Invoke-MessageAlert -ChatId $ChatId -Messages $UnreadGroupMentions
        }
        else {
            Write-Host ("[" + (Get-LogTimestamp) + "] " + "Group unread mentions: none")
        }
    }

    Start-Sleep -Seconds $IntervalSeconds
}

