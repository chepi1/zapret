# Fetch the pinned official binary; no execution and no runtime/settings changes.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tools/tgws.ps1')
$release=Get-TgWsRelease
$stage=Join-Path $root ('dist/upstream/tg-ws-proxy-'+$release.Tag)
New-Item -ItemType Directory -Path $stage -Force|Out-Null
$temporary=Join-Path $stage ([guid]::NewGuid().ToString('N')+'.download')
try{
    Invoke-WebRequest -Uri $release.Url -OutFile $temporary -UseBasicParsing -TimeoutSec 120
    if((Get-Item -LiteralPath $temporary).Length -ne $release.Bytes -or (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -ine $release.Sha256){throw 'Official TG WS Proxy asset differs from its published digest.'}
    $target=Join-Path $root $release.RelativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force|Out-Null
    Copy-Item -LiteralPath $temporary -Destination $target -ErrorAction Stop
    Assert-TgWsBinary $root|Out-Null
    Write-Output ('Verified official TG WS Proxy '+$release.Tag+' ('+$release.Bytes+' bytes)')
}finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
