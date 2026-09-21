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
    "macro_controller.lua",
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
    "lab_controller.lua",
    "unit_controller.lua",
    "bar_framework\resource_utils.lua",
    "bar_framework\unit_query.lua"
)

foreach ($f in $files) {
    $target = Join-Path $dst $f
    New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
    Copy-Item (Join-Path $src $f) $target -Force
    Write-Host "Copied $f"
}

Write-Host "`nDone."
