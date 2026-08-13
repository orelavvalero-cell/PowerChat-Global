#requires -Version 5.1

[CmdletBinding()]
param(
    [switch] $ValidateOnly,
    [switch] $StickerPreview
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($PSVersionTable.PSEdition -eq 'Desktop') {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

$script:ChatName = 'PowerChat Global'
$script:SupabaseUrl = 'https://nuygiylrrtzlelgalgsq.supabase.co'
$script:PublishableKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im51eWdpeWxycnR6bGVsZ2FsZ3NxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODY0OTgwNjksImV4cCI6MjEwMjA3NDA2OX0.QqbvLUbNODT-HjMyWYNRNIMaaljCrhP4RbgZJA1l2SU'
$script:Logo = @'
8888888b.                                      .d8888b. 888             888
888   Y88b                                    d88P  Y88b888             888
888    888                                    888    888888             888
888   d88P .d88b. 888  888  888 .d88b. 888d888888       88888b.  8888b. 888888
8888888P" d88""88b888  888  888d8P  Y8b888P"  888       888 "88b    "88b888
888       888  888888  888  88888888888888    888    888888  888.d888888888
888       Y88..88PY88b 888 d88PY8b.    888    Y88b  d88P888  888888  888Y88b.
888        "Y88P"  "Y8888888P"  "Y8888 888     "Y8888P" 888  888"Y888888 "Y888
'@

$userProfilePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
if ([string]::IsNullOrWhiteSpace($userProfilePath)) {
    throw 'Cannot determine the current user profile directory.'
}

$script:IsWindowsPlatform = ($PSVersionTable.PSEdition -eq 'Desktop') -or ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
$script:StateDirectory = if ($script:IsWindowsPlatform) {
    Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'PowerChat'
}
else {
    Join-Path $userProfilePath '.powerchat'
}
$script:SessionPath = Join-Path $script:StateDirectory 'session.json'
$script:Session = $null
$script:LastMessageId = [long]0
$script:Nickname = ''
$script:NotificationIcon = $null
$script:StickerNames = @('heart', 'smile', 'cat', 'flower', 'rocket', 'party')

function Get-ApiErrorText {
    param([Parameter(Mandatory)] $ErrorRecord)

    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        try {
            $details = $ErrorRecord.ErrorDetails.Message | ConvertFrom-Json
            foreach ($property in 'msg', 'message', 'error_description', 'error', 'details', 'hint') {
                if ($details.PSObject.Properties.Name -contains $property -and $details.$property) {
                    return [string]$details.$property
                }
            }
        }
        catch {
            return [string]$ErrorRecord.ErrorDetails.Message
        }
    }

    return [string]$ErrorRecord.Exception.Message
}

function Invoke-PowerChatApi {
    param(
        [Parameter(Mandatory)] [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')] [string] $Method,
        [Parameter(Mandatory)] [string] $Path,
        [AllowNull()] $Body = $null,
        [string] $AccessToken,
        [hashtable] $ExtraHeaders = @{}
    )

    $headers = @{
        apikey = $script:PublishableKey
    }
    if ($AccessToken) {
        $headers.Authorization = "Bearer $AccessToken"
    }
    foreach ($entry in $ExtraHeaders.GetEnumerator()) {
        $headers[$entry.Key] = $entry.Value
    }

    $request = @{
        Method      = $Method
        Uri         = "$($script:SupabaseUrl)$Path"
        Headers     = $headers
        ContentType = 'application/json; charset=utf-8'
        TimeoutSec  = 20
    }
    if ($null -ne $Body) {
        $request.Body = $Body | ConvertTo-Json -Depth 8 -Compress
    }

    try {
        return Invoke-RestMethod @request
    }
    catch {
        $message = Get-ApiErrorText -ErrorRecord $_
        throw [InvalidOperationException]::new($message, $_.Exception)
    }
}

function Save-ChatSession {
    New-Item -ItemType Directory -Path $script:StateDirectory -Force | Out-Null
    $sessionJson = $script:Session | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($script:SessionPath, $sessionJson, [Text.UTF8Encoding]::new($false))
}

function Load-ChatSession {
    if (-not (Test-Path -LiteralPath $script:SessionPath)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $script:SessionPath -Raw | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Set-SessionFromResponse {
    param(
        [Parameter(Mandatory)] $Response,
        [string] $ExistingNickname = ''
    )

    if (-not $Response.access_token -or -not $Response.refresh_token -or -not $Response.user.id) {
        throw 'Supabase returned an incomplete anonymous session.'
    }

    $lifetime = if ($Response.expires_in) { [int]$Response.expires_in } else { 3600 }
    $script:Session = [pscustomobject]@{
        access_token  = [string]$Response.access_token
        refresh_token = [string]$Response.refresh_token
        user_id       = [string]$Response.user.id
        expires_at    = [DateTimeOffset]::UtcNow.AddSeconds([Math]::Max(60, $lifetime - 90)).ToString('o')
        nickname      = $ExistingNickname
    }
    Save-ChatSession
}

function Connect-AnonymousUser {
    $saved = Load-ChatSession
    if ($saved -and $saved.refresh_token -and $saved.user_id) {
        try {
            $expiresAt = [DateTimeOffset]::MinValue
            if ($saved.expires_at) {
                [DateTimeOffset]::TryParse([string]$saved.expires_at, [ref]$expiresAt) | Out-Null
            }

            if ($saved.access_token -and $expiresAt -gt [DateTimeOffset]::UtcNow) {
                $script:Session = $saved
                return
            }

            $refreshed = Invoke-PowerChatApi -Method POST -Path '/auth/v1/token?grant_type=refresh_token' -Body @{
                refresh_token = [string]$saved.refresh_token
            }
            Set-SessionFromResponse -Response $refreshed -ExistingNickname ([string]$saved.nickname)
            return
        }
        catch {
            Write-Host 'Saved guest session has expired. Creating a new guest...' -ForegroundColor Yellow
        }
    }

    try {
        $created = Invoke-PowerChatApi -Method POST -Path '/auth/v1/signup' -Body @{}
        Set-SessionFromResponse -Response $created
    }
    catch {
        throw "Guest entry failed: $($_.Exception.Message)`nEnable the technical Anonymous Sign-Ins option in Supabase Authentication settings. Users will not see it."
    }
}

function Get-OwnProfile {
    $rows = @(Invoke-PowerChatApi -Method GET -Path "/rest/v1/profiles?select=nickname&user_id=eq.$($script:Session.user_id)&limit=1" -AccessToken $script:Session.access_token)
    if ($rows.Count -gt 0) {
        return $rows[0]
    }
    return $null
}

function Test-Nickname {
    param([string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value -ne $Value.Trim()) { return $false }
    if ($Value.Length -lt 2 -or $Value.Length -gt 24) { return $false }
    if ($Value -match '[\x00-\x1F\x7F]') { return $false }
    return $true
}

function Register-Nickname {
    param([Parameter(Mandatory)] [string] $Value)

    Invoke-PowerChatApi -Method POST -Path '/rest/v1/profiles' -Body @{
        user_id  = [string]$script:Session.user_id
        nickname = $Value
    } -AccessToken $script:Session.access_token -ExtraHeaders @{ Prefer = 'return=minimal' } | Out-Null

    $script:Nickname = $Value
    $script:Session.nickname = $Value
    Save-ChatSession
}

function Select-Nickname {
    $profile = Get-OwnProfile
    if ($profile -and $profile.nickname) {
        $script:Nickname = [string]$profile.nickname
        $script:Session.nickname = $script:Nickname
        Save-ChatSession
        return
    }

    while ($true) {
        Write-Host ''
        $candidate = Read-Host 'Choose a nickname (2-24 characters)'
        if (-not (Test-Nickname -Value $candidate)) {
            Write-Host 'Nickname must be 2-24 characters and cannot contain control characters.' -ForegroundColor Yellow
            continue
        }

        try {
            Register-Nickname -Value $candidate
            return
        }
        catch {
            if ($_.Exception.Message -match 'duplicate|unique|already exists') {
                Write-Host 'That nickname is already taken.' -ForegroundColor Yellow
            }
            else {
                throw
            }
        }
    }
}

function Update-Nickname {
    param([Parameter(Mandatory)] [string] $Value)

    if (-not (Test-Nickname -Value $Value)) {
        throw 'Nickname must be 2-24 characters.'
    }

    Invoke-PowerChatApi -Method PATCH -Path "/rest/v1/profiles?user_id=eq.$($script:Session.user_id)" -Body @{
        nickname = $Value
    } -AccessToken $script:Session.access_token -ExtraHeaders @{ Prefer = 'return=minimal' } | Out-Null

    $script:Nickname = $Value
    $script:Session.nickname = $Value
    Save-ChatSession
}

function Get-NewMessages {
    param([switch] $Initial)

    if ($Initial) {
        $path = '/rest/v1/messages?select=id,user_id,content,created_at,profiles!messages_user_id_fkey(nickname)&order=id.desc&limit=50'
    }
    else {
        $path = "/rest/v1/messages?select=id,user_id,content,created_at,profiles!messages_user_id_fkey(nickname)&id=gt.$($script:LastMessageId)&order=id.asc&limit=100"
    }

    $rawMessages = Invoke-PowerChatApi -Method GET -Path $path -AccessToken $script:Session.access_token
    $messages = @($rawMessages | Where-Object {
        $null -ne $_ -and
        $_.PSObject.Properties.Name -contains 'id' -and
        [string]$_.id -match '^\d+$' -and
        [long]$_.id -gt 0 -and
        $_.PSObject.Properties.Name -contains 'content' -and
        $null -ne $_.content
    })
    if ($Initial) {
        $messages = @($messages | Sort-Object { [long]$_.id })
    }
    return $messages
}

function Get-ChatStickerDefinition {
    param([Parameter(Mandatory)] [string] $Name)

    switch ($Name.ToLowerInvariant()) {
        'heart' {
            return [pscustomobject]@{
                Name = 'heart'; Title = 'HEART'
                Lines = @('   **     **', ' ****** ******', '*************', ' ***********', '   *******', '     ***', '      *')
                Colors = @('Magenta', 'Red', 'DarkRed', 'Red', 'Magenta', 'DarkMagenta', 'Red')
            }
        }
        'smile' {
            return [pscustomobject]@{
                Name = 'smile'; Title = 'SMILE'
                Lines = @('   .-------.', '  /  o   o  \', ' |     ^     |', ' |   \___/   |', '  \         /', "   '-------'")
                Colors = @('Yellow', 'DarkYellow', 'Yellow', 'Green', 'DarkYellow', 'Yellow')
            }
        }
        'cat' {
            return [pscustomobject]@{
                Name = 'cat'; Title = 'CAT'
                Lines = @(' /\_/\', '( o.o )', ' > ^ <', ' /|_|\', '  / \')
                Colors = @('Cyan', 'White', 'Magenta', 'DarkCyan', 'Cyan')
            }
        }
        'flower' {
            return [pscustomobject]@{
                Name = 'flower'; Title = 'FLOWER'
                Lines = @('    .-.', ' .-(   )-.', '(   \ /   )', " '-( * )-'", '    | |', '   /| |\', '  /_| |_\')
                Colors = @('Magenta', 'Red', 'Magenta', 'Yellow', 'Green', 'DarkGreen', 'Green')
            }
        }
        'rocket' {
            return [pscustomobject]@{
                Name = 'rocket'; Title = 'ROCKET'
                Lines = @('      /\', '     /  \', '    | () |', '    |    |', '   /|____|\', '     /\/\', '    /_||_\')
                Colors = @('White', 'Cyan', 'Yellow', 'White', 'DarkCyan', 'Red', 'DarkRed')
            }
        }
        'party' {
            return [pscustomobject]@{
                Name = 'party'; Title = 'PARTY'
                Lines = @('*   .  *   .', '  \  |  /', '---  *  ---', '  /  |  \', '.   /\   *', '   /##\', '  /####\')
                Colors = @('Magenta', 'Cyan', 'Yellow', 'Green', 'Red', 'DarkMagenta', 'Magenta')
            }
        }
        default { return $null }
    }
}

function Get-StickerNameFromContent {
    param([AllowEmptyString()] [string] $Content)

    $match = [regex]::Match($Content, '^\[\[powerchat-sticker:([a-z0-9_-]+)\]\]$')
    if (-not $match.Success) {
        return $null
    }

    $name = $match.Groups[1].Value
    if ($null -eq (Get-ChatStickerDefinition -Name $name)) {
        return $null
    }
    return $name
}

function Write-ChatSticker {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [string] $Indent = '    '
    )

    $sticker = Get-ChatStickerDefinition -Name $Name
    if ($null -eq $sticker) {
        return
    }

    for ($index = 0; $index -lt $sticker.Lines.Count; $index++) {
        Write-Host ($Indent + $sticker.Lines[$index]) -ForegroundColor $sticker.Colors[$index]
    }
}

function Show-StickerGallery {
    Write-Host ''
    Write-Host 'POWERCHAT STICKERS' -ForegroundColor Cyan
    Write-Host 'Send one with: /sticker name' -ForegroundColor DarkGray
    foreach ($stickerName in $script:StickerNames) {
        $sticker = Get-ChatStickerDefinition -Name $stickerName
        Write-Host ''
        Write-Host ("  {0,-8} /sticker {1}" -f $sticker.Title, $sticker.Name) -ForegroundColor White
        Write-ChatSticker -Name $sticker.Name -Indent '  '
    }
    Write-Host ''
}

function Write-ChatMessage {
    param([Parameter(Mandatory)] $Message)

    if (
        $null -eq $Message -or
        -not ($Message.PSObject.Properties.Name -contains 'id') -or
        [string]$Message.id -notmatch '^\d+$' -or
        [long]$Message.id -le 0 -or
        -not ($Message.PSObject.Properties.Name -contains 'content')
    ) {
        return
    }

    $messageId = [long]$Message.id
    if ($messageId -gt $script:LastMessageId) {
        $script:LastMessageId = $messageId
    }

    $time = try { ([DateTimeOffset]::Parse([string]$Message.created_at)).ToLocalTime().ToString('HH:mm') } catch { '--:--' }
    $name = if ($Message.profiles -and $Message.profiles.nickname) { [string]$Message.profiles.nickname } else { 'Guest' }
    $text = ([string]$Message.content) -replace '[\r\n]+', ' '
    $own = ([string]$Message.user_id -eq [string]$script:Session.user_id)
    $stickerName = Get-StickerNameFromContent -Content ([string]$Message.content)

    Write-Host "[$time] " -NoNewline -ForegroundColor DarkGray
    Write-Host "$name " -NoNewline -ForegroundColor $(if ($own) { 'Cyan' } else { 'Magenta' })
    Write-Host "#$messageId" -NoNewline -ForegroundColor DarkGray
    if ($stickerName) {
        $sticker = Get-ChatStickerDefinition -Name $stickerName
        Write-Host ": sticker $($sticker.Title)" -ForegroundColor Yellow
        Write-ChatSticker -Name $stickerName
    }
    else {
        Write-Host ": $text"
    }
}

function Send-ChatMessage {
    param([Parameter(Mandatory)] [string] $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    if ($Text.Length -gt 500) {
        throw 'A message can contain no more than 500 characters.'
    }

    Invoke-PowerChatApi -Method POST -Path '/rest/v1/messages' -Body @{
        content = $Text
    } -AccessToken $script:Session.access_token -ExtraHeaders @{ Prefer = 'return=minimal' } | Out-Null
}

function Send-ChatSticker {
    param([Parameter(Mandatory)] [string] $Name)

    $sticker = Get-ChatStickerDefinition -Name $Name
    if ($null -eq $sticker) {
        throw "Unknown sticker '$Name'. Type /stickers to see the collection."
    }

    Send-ChatMessage -Text "[[powerchat-sticker:$($sticker.Name)]]"
}

function Remove-OwnMessage {
    param([Parameter(Mandatory)] [long] $MessageId)

    Invoke-PowerChatApi -Method DELETE -Path "/rest/v1/messages?id=eq.$MessageId" -AccessToken $script:Session.access_token -ExtraHeaders @{ Prefer = 'return=minimal' } | Out-Null
}

function Send-MessageReport {
    param(
        [Parameter(Mandatory)] [long] $MessageId,
        [Parameter(Mandatory)] [string] $Reason
    )

    if ($Reason.Length -gt 200) {
        $Reason = $Reason.Substring(0, 200)
    }
    Invoke-PowerChatApi -Method POST -Path '/rest/v1/reports' -Body @{
        message_id = $MessageId
        reason     = $Reason
    } -AccessToken $script:Session.access_token -ExtraHeaders @{ Prefer = 'return=minimal' } | Out-Null
}

function Update-Presence {
    Invoke-PowerChatApi -Method PATCH -Path "/rest/v1/profiles?user_id=eq.$($script:Session.user_id)" -Body @{
        last_seen = [DateTimeOffset]::UtcNow.ToString('o')
    } -AccessToken $script:Session.access_token -ExtraHeaders @{ Prefer = 'return=minimal' } | Out-Null

    $count = Invoke-PowerChatApi -Method POST -Path '/rest/v1/rpc/chat_online_count' -Body @{} -AccessToken $script:Session.access_token
    try { [Console]::Title = "$($script:ChatName) - $count online - $($script:Nickname)" } catch { }
}

function Clear-CurrentInputLine {
    $width = try { [Console]::WindowWidth } catch { 100 }
    $spaces = ' ' * [Math]::Max(1, $width - 1)
    Write-Host "`r$spaces`r" -NoNewline
}

function Show-PowerChatLogo {
    Write-Host $script:Logo -ForegroundColor Cyan
}

function Initialize-WindowsNotifications {
    if (-not $script:IsWindowsPlatform -or $null -ne $script:NotificationIcon) {
        return
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        $script:NotificationIcon = [System.Windows.Forms.NotifyIcon]::new()
        $script:NotificationIcon.Icon = [System.Drawing.SystemIcons]::Information
        $script:NotificationIcon.Text = $script:ChatName
        $script:NotificationIcon.Visible = $true
    }
    catch {
        $script:NotificationIcon = $null
    }
}

function Show-WindowsMessageNotification {
    param([Parameter(Mandatory)] $Message)

    if (
        $null -eq $script:NotificationIcon -or
        [string]$Message.user_id -eq [string]$script:Session.user_id
    ) {
        return
    }

    try {
        $sender = if ($Message.profiles -and $Message.profiles.nickname) {
            [string]$Message.profiles.nickname
        }
        else {
            'New message'
        }
        $stickerName = Get-StickerNameFromContent -Content ([string]$Message.content)
        if ($stickerName) {
            $sticker = Get-ChatStickerDefinition -Name $stickerName
            $preview = "Sent a sticker: $($sticker.Title)"
        }
        else {
            $preview = (([string]$Message.content) -replace '[\r\n]+', ' ').Trim()
        }
        if ($preview.Length -gt 200) {
            $preview = $preview.Substring(0, 197) + '...'
        }

        $script:NotificationIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        $script:NotificationIcon.BalloonTipTitle = $sender
        $script:NotificationIcon.BalloonTipText = $preview
        $script:NotificationIcon.ShowBalloonTip(5000)
    }
    catch {
        # Notifications must never interrupt the chat.
    }
}

function Close-WindowsNotifications {
    if ($null -eq $script:NotificationIcon) {
        return
    }

    try {
        $script:NotificationIcon.Visible = $false
        $script:NotificationIcon.Dispose()
    }
    finally {
        $script:NotificationIcon = $null
    }
}

function Write-InputPrompt {
    param([Parameter(Mandatory)] [Text.StringBuilder] $Buffer)

    Write-Host "[$($script:Nickname)]" -NoNewline -ForegroundColor Cyan
    Write-Host ' > ' -NoNewline -ForegroundColor DarkGray
    Write-Host $Buffer.ToString() -NoNewline
}

function Show-Help {
    Write-Host ''
    Write-Host 'Commands:' -ForegroundColor Cyan
    Write-Host '  /help                 show this help'
    Write-Host '  /stickers             show all colored stickers'
    Write-Host '  /sticker heart        send a colored sticker'
    Write-Host '  /nick NewName         change your nickname'
    Write-Host '  /delete 123           delete your own message'
    Write-Host '  /report 123 reason    report a message to moderators'
    Write-Host '  /clear                clear the screen'
    Write-Host '  /quit                 leave the chat'
    Write-Host ''
}

function Invoke-ChatCommand {
    param([Parameter(Mandatory)] [string] $Line)

    if (-not $Line.StartsWith('/')) {
        Send-ChatMessage -Text $Line
        return $true
    }

    $parts = $Line.Split(' ', 3, [StringSplitOptions]::RemoveEmptyEntries)
    $command = $parts[0].ToLowerInvariant()
    switch ($command) {
        '/help' {
            Show-Help
        }
        '/stickers' {
            Show-StickerGallery
        }
        '/sticker' {
            if ($parts.Count -lt 2) { throw 'Usage: /sticker heart. Type /stickers to see all names.' }
            Send-ChatSticker -Name $parts[1]
        }
        '/nick' {
            if ($parts.Count -lt 2) { throw 'Usage: /nick NewName' }
            Update-Nickname -Value $Line.Substring(6).Trim()
            Write-Host "Nickname changed to $($script:Nickname)." -ForegroundColor Green
        }
        '/delete' {
            if ($parts.Count -lt 2 -or $parts[1] -notmatch '^\d+$') { throw 'Usage: /delete 123' }
            Remove-OwnMessage -MessageId ([long]$parts[1])
            Write-Host 'Delete request completed.' -ForegroundColor Green
        }
        '/report' {
            if ($parts.Count -lt 2 -or $parts[1] -notmatch '^\d+$') { throw 'Usage: /report 123 reason' }
            $reason = if ($parts.Count -ge 3) { $parts[2] } else { 'Not specified' }
            Send-MessageReport -MessageId ([long]$parts[1]) -Reason $reason
            Write-Host 'Thank you. The report was saved for moderators.' -ForegroundColor Green
        }
        '/clear' {
            Clear-Host
            Show-PowerChatLogo
            Write-Host "  $($script:ChatName)" -ForegroundColor Cyan
        }
        '/quit' {
            return $false
        }
        default {
            throw 'Unknown command. Type /help.'
        }
    }
    return $true
}

function Start-ChatLoop {
    Clear-Host
    Show-PowerChatLogo
    Write-Host ('=' * 64) -ForegroundColor DarkCyan
    Write-Host "  $($script:ChatName)" -ForegroundColor Cyan
    Write-Host "  Your saved nickname: $($script:Nickname)" -ForegroundColor DarkGray
    Write-Host '  Public room: messages are visible to every participant.' -ForegroundColor Yellow
    Write-Host '  Type /help for commands.' -ForegroundColor DarkGray
    Write-Host ('=' * 64) -ForegroundColor DarkCyan

    $history = @(Get-NewMessages -Initial)
    foreach ($message in $history) {
        Write-ChatMessage -Message $message
    }

    Initialize-WindowsNotifications
    Update-Presence
    $buffer = [Text.StringBuilder]::new()
    $lastPoll = [DateTimeOffset]::UtcNow
    $lastPresence = [DateTimeOffset]::UtcNow
    $running = $true
    $oldTreatControlC = [Console]::TreatControlCAsInput
    [Console]::TreatControlCAsInput = $true
    Write-InputPrompt -Buffer $buffer

    try {
        while ($running) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq [ConsoleKey]::Enter) {
                    $line = $buffer.ToString()
                    $null = $buffer.Clear()
                    Clear-CurrentInputLine
                    if (-not [string]::IsNullOrWhiteSpace($line)) {
                        try {
                            $running = Invoke-ChatCommand -Line $line.Trim()
                        }
                        catch {
                            Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
                        }
                    }
                    if ($running) { Write-InputPrompt -Buffer $buffer }
                }
                elseif ($key.Key -eq [ConsoleKey]::Backspace) {
                    if ($buffer.Length -gt 0) {
                        $null = $buffer.Remove($buffer.Length - 1, 1)
                        Clear-CurrentInputLine
                        Write-InputPrompt -Buffer $buffer
                    }
                }
                elseif ($key.Key -eq [ConsoleKey]::Escape) {
                    $null = $buffer.Clear()
                    Clear-CurrentInputLine
                    Write-InputPrompt -Buffer $buffer
                }
                elseif ($key.Key -eq [ConsoleKey]::C -and ($key.Modifiers -band [ConsoleModifiers]::Control)) {
                    $running = $false
                }
                elseif (-not [char]::IsControl($key.KeyChar)) {
                    $null = $buffer.Append($key.KeyChar)
                    Write-Host $key.KeyChar -NoNewline
                }
            }

            $now = [DateTimeOffset]::UtcNow
            if (($now - $lastPoll).TotalMilliseconds -ge 1200) {
                $lastPoll = $now
                try {
                    $newMessages = @(Get-NewMessages)
                    if ($newMessages.Count -gt 0) {
                        Clear-CurrentInputLine
                        foreach ($message in $newMessages) {
                            Write-ChatMessage -Message $message
                            Show-WindowsMessageNotification -Message $message
                        }
                        Write-InputPrompt -Buffer $buffer
                    }
                }
                catch {
                    # A temporary connection error should not close the chat.
                }
            }

            if (($now - $lastPresence).TotalSeconds -ge 20) {
                $lastPresence = $now
                try { Update-Presence } catch { }
            }

            Start-Sleep -Milliseconds 35
        }
    }
    finally {
        Close-WindowsNotifications
        [Console]::TreatControlCAsInput = $oldTreatControlC
        Clear-CurrentInputLine
        Write-Host 'Disconnected from PowerChat. See you soon!' -ForegroundColor Cyan
    }
}

if ($StickerPreview) {
    Show-StickerGallery
    exit 0
}

if ($ValidateOnly) {
    Write-Output "PowerChat validation passed: $($script:ChatName)"
    exit 0
}

try {
    Connect-AnonymousUser
    Select-Nickname
    Start-ChatLoop
}
catch {
    Write-Host ''
    Write-Host "PowerChat could not start: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Check README.md and run supabase-setup.sql in your Supabase project.' -ForegroundColor Yellow
    exit 1
}
