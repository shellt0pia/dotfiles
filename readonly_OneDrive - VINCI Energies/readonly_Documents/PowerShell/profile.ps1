Function Prompt {
    $Path = Split-Path -Leaf -Path (Get-Location)
    "$Path > "
}
New-Alias ll Get-ChildItem

Clear-Host
