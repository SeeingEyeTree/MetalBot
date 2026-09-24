param([string]$Bot = "DRAGON_BOT")

$src = "$PSScriptRoot"

# Locate the BAR data directory, checking common install locations.
$barCandidates = @(
    "$env:LOCALAPPDATA\Programs\Beyond-All-Reason",
    "$env:ProgramFiles\Beyond-All-Reason",
    "${env:ProgramFiles(x86)}\Beyond-All-Reason"
)
$barBase = $barCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $barBase) {
    Write-Error "Beyond All Reason install not found. Set `$barBase manually or install BAR to a standard location."
    exit 1
}

$dst = "$barBase\data\LuaUI\Widgets"
Write-Host "Deploying to: $dst"
# do not add new_bot.lua and bot.lua
$files = @(
    "blueprint_placer.lua",
    "blueprints_data.lua",
    "blueprints\general\com_starter.lua",
    "blueprints\general\bot_starter.lua",
    "blueprints\general\mex_grid_aa_corner.lua",
    "blueprints\general\empty_grid.lua",
    "blueprints\general\VechT1_and_BotT2.lua",
    "blueprints\general\energy_grid_t1.lua",
    "blueprints\general\4AirT2.lua",
    "blueprints\general\fussion_grid_60x60.lua",
    "blueprints\general\mex_grid_t2.lua",
    "blueprints\general\prod_grid_vp.lua",
    "blueprints\general\build_order_blueprint.lua",
    "blueprints\general\mex_grid_alab.lua",
    "blueprints\general\upgrade.lua",
    "blueprints\general\raider_blueprint.lua",
    "blueprints\general\ground_raider_blueprint.lua",
    "metalbot_stats_tracker.lua",
    "bar_framework\escape_guard.lua",
    "bar_framework\nano_broker.lua",
    "bar_framework\resource_utils.lua",
    "bar_framework\unit_query.lua",
    "bar_framework\threat_map.lua",
    "bar_framework\army_broker.lua",
    "bar_framework\scout_plan.lua",
    "bar_framework\map_model.lua",
    "bar_framework\threat_log.lua"
)

# The three controllers come from the bot folder (default DRAGON_BOT; pass -Bot OK_BOT etc.).
# An absolute path also works. Shared files above always come from the repo root.
$botDir = if ([System.IO.Path]::IsPathRooted($Bot)) { $Bot } else { Join-Path $src $Bot }
if (-not (Test-Path $botDir)) {
    Write-Error "Bot folder not found: $botDir"
    exit 1
}
Write-Host "Bot: $botDir"

foreach ($f in $files) {
    $target = Join-Path $dst $f
    New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
    Copy-Item (Join-Path $src $f) $target -Force
    Write-Host "Copied $f"
}

foreach ($f in @("macro_controller.lua", "lab_controller.lua", "unit_controller.lua")) {
    Copy-Item (Join-Path $botDir $f) (Join-Path $dst $f) -Force
    Write-Host "Copied $Bot\$f"
}

Write-Host "`nDone."
