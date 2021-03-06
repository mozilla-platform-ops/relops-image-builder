param (
  [string] $target_worker_type,
  [string] $source_org = 'mozilla-platform-ops',
  [string] $source_repo = 'relops-image-builder',
  [string] $source_ref = 'master'
)

foreach ($env_var in (Get-ChildItem -Path 'Env:')) {
  Write-Host -object ('{0}: {1}' -f $env_var.Name, $env_var.Value) -ForegroundColor DarkGray
}

$worker_type_map = (Invoke-WebRequest -Uri ('https://raw.githubusercontent.com/{0}/{1}/{2}/worker-type-map.json?{3}' -f $source_org, $source_repo, $source_ref, [Guid]::NewGuid()) -UseBasicParsing | ConvertFrom-Json)
$manifest = (Invoke-WebRequest -Uri ('https://raw.githubusercontent.com/{0}/{1}/{2}/manifest.json?{3}' -f $source_org, $source_repo, $source_ref, [Guid]::NewGuid()) -UseBasicParsing | ConvertFrom-Json)
$config = @($manifest | Where-Object {
  $_.os -eq 'Windows' -and
  $_.build.major -eq $worker_type_map."$target_worker_type".build.major -and
  $_.build.release -eq $worker_type_map."$target_worker_type".build.release -and
  $_.build.build -eq $worker_type_map."$target_worker_type".build.build -and
  $_.version -eq $worker_type_map."$target_worker_type".version -and
  $_.edition -eq $worker_type_map."$target_worker_type".edition -and
  $_.language -eq $worker_type_map."$target_worker_type".language -and
  $_.architecture -eq $worker_type_map."$target_worker_type".architecture
})[0]

if (-not $config) {
  throw [System.ArgumentOutOfRangeException] ('failed to determine configuration for Windows build: {0}.{1}.{2}, version: {3}, edition: {4}, language: {5}, architecture: {6}' -f $worker_type_map."$target_worker_type".build.major, $worker_type_map."$target_worker_type".build.release, $worker_type_map."$target_worker_type".build.build, $worker_type_map."$target_worker_type".version, $worker_type_map."$target_worker_type".edition, $worker_type_map."$target_worker_type".language, $worker_type_map."$target_worker_type".architecture)
}

$image_capture_date = ((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))
$image_description = ('{0} {1} ({2}) - edition: {3}, language: {4}, partition: {5}, captured: {6}' -f $config.os, $config.build.major, $config.version, $config.edition, $config.language, $config.partition, $image_capture_date)

$aws_region = 'us-west-2'
$aws_availability_zone = ('{0}c' -f $aws_region)

$cwi_url = ('https://raw.githubusercontent.com/{0}/{1}/{2}/Convert-WindowsImage.ps1' -f $source_org, $source_repo, $source_ref)
$work_dir = (Resolve-Path -Path '.\').Path
$cwi_path = (Join-Path -Path $work_dir -ChildPath ([System.IO.Path]::GetFileName($cwi_url)))
$ua_path = (Join-Path -Path $work_dir -ChildPath ([System.IO.Path]::GetFileName($config.unattend)))
$iso_path = (Join-Path -Path $work_dir -ChildPath ([System.IO.Path]::GetFileName($config.iso.key)))
$vhd_path = (Join-Path -Path $work_dir -ChildPath ([System.IO.Path]::GetFileName($config.vhd.key)))

Write-Host -object ('work_dir: {0}' -f $work_dir) -ForegroundColor DarkGray
Write-Host -object ('iso_path: {0}' -f $iso_path) -ForegroundColor DarkGray

Set-ExecutionPolicy RemoteSigned

# install GoogleCloud powershell module if not installed
if (-not (Get-Module -ListAvailable -Name 'GoogleCloud' -ErrorAction 'SilentlyContinue')) {
  try {
    Install-Module -Name 'GoogleCloud'
    Write-Host -object 'installed powershell module: GoogleCloud' -ForegroundColor White
  } catch {
    if ($_.Exception.InnerException) {
      Write-Host -object $_.Exception.InnerException.Message -ForegroundColor DarkYellow
    }
    Write-Host -object $_.Exception.Message -ForegroundColor Red
  }
} else {
  Write-Host -object 'detected powershell module: GoogleCloud' -ForegroundColor DarkGray
}
# install nuget package provider if not installed
$nugetPackageProvider = (Get-PackageProvider -Name 'NuGet' -ErrorAction 'SilentlyContinue')
if ((-not ($nugetPackageProvider)) -or ($nugetPackageProvider.Version -lt 2.8.5.201)) {
  try {
    Install-PackageProvider -Name 'NuGet' -MinimumVersion 2.8.5.201 -Force
    Write-Host -object 'installed package provider: NuGet' -ForegroundColor White
  } catch {
    if ($_.Exception.InnerException) {
      Write-Host -object $_.Exception.InnerException.Message -ForegroundColor DarkYellow
    }
    Write-Host -object $_.Exception.Message -ForegroundColor Red
  }
} else {
  Write-Host -object ('detected package provider: NuGet {0}' -f $nugetPackageProvider.Version) -ForegroundColor DarkGray
}

$vhd_key = $(if ($source_ref.Length -eq 40) { ($config.vhd.key.Replace('vhd/', ('vhd/{0}/' -f $source_ref.SubString(0, 7)))) } else { $config.vhd.key })
if (-not (Get-GcsObject -Bucket $config.vhd.bucket -ObjectName $vhd_key -ErrorAction SilentlyContinue)) {

  # download the iso file if not on the local filesystem
  if (-not (Test-Path -Path $iso_path -ErrorAction 'SilentlyContinue')) {
    Write-Host -object ('downloading {0} from bucket {1} with key {2}' -f $iso_path, $config.iso.bucket, $config.iso.key) -ForegroundColor White
    Read-GcsObject -Bucket $config.iso.bucket -ObjectName $config.iso.key -OutFile $iso_path
    if  (Test-Path -Path $iso_path -ErrorAction 'SilentlyContinue') {
      Write-Host -object ('downloaded {0} from bucket {1} with key {2}' -f $iso_path, $config.iso.bucket, $config.iso.key) -ForegroundColor White
    } else {
      Write-Host -object ('failed to download {0} from bucket {1} with key {2}. aborting...' -f $iso_path, $config.iso.bucket, $config.iso.key) -ForegroundColor Red
      exit
    }
  } else {
    Write-Host -object ('iso detected at: {0}' -f $iso_path) -ForegroundColor DarkGray
  }

  # download the vhd conversion script
  if (Test-Path -Path $cwi_path -ErrorAction 'SilentlyContinue') {
    Remove-Item -Path $cwi_path -Force
  }
  try {
    (New-Object Net.WebClient).DownloadFile($cwi_url, $cwi_path)
    Write-Host -object ('downloaded {0} to {1}' -f $cwi_url, $cwi_path) -ForegroundColor White
  } catch {
    if ($_.Exception.InnerException) {
      Write-Host -object $_.Exception.InnerException.Message -ForegroundColor DarkYellow
    }
    Write-Host -object $_.Exception.Message -ForegroundColor Red
  }

  # delete the unattend file if it exists
  if (Test-Path -Path $ua_path -ErrorAction SilentlyContinue) {
    Remove-Item -Path $ua_path -Force
  }
  # download the unattend file
  try {
    (New-Object Net.WebClient).DownloadFile($config.unattend.Replace('/unattend/', '/unattend/gcp/').Replace('mozilla-platform-ops/relops-image-builder/master', ('{0}/{1}/{2}' -f $source_org, $source_repo, $source_ref)), $ua_path)
    Write-Host -object ('downloaded {0} to {1}' -f $config.unattend.Replace('/unattend/', '/unattend/gcp/').Replace('mozilla-platform-ops/relops-image-builder/master', ('{0}/{1}/{2}' -f $source_org, $source_repo, $source_ref)), $ua_path) -ForegroundColor White
  } catch {
    if ($_.Exception.InnerException) {
      Write-Host -object $_.Exception.InnerException.Message -ForegroundColor DarkYellow
    }
    Write-Host -object $_.Exception.Message -ForegroundColor Red
  }

  # download driver files if not on the local filesystem
  $drivers = @()
  foreach ($driver in $config.drivers) {
    $local_path = (Join-Path -Path $work_dir -ChildPath ([System.IO.Path]::GetFileName($driver.key)))
    if (Test-Path -Path $local_path -ErrorAction SilentlyContinue) {
      Remove-Item $local_path -Force -Recurse
      Write-Host -object ('deleted: {0}' -f $local_path) -ForegroundColor DarkGray
    }
    try {
      Write-Host -object ('downloading {0} from bucket {1} with key {2}' -f $local_path, $driver.bucket, $driver.key) -ForegroundColor White
      Read-GcsObject -Bucket $driver.bucket -ObjectName $driver.key -OutFile $local_path
      if (Test-Path -Path $local_path -ErrorAction SilentlyContinue) {
        Write-Host -object ('downloaded {0} from bucket {1} with key {2}' -f (Resolve-Path -Path $local_path), $driver.bucket, $driver.key) -ForegroundColor White
      } else {
        Write-Host -object ('failed to download {0} from bucket {1} with key {2}' -f $local_path, $driver.bucket, $driver.key) -ForegroundColor Red
        exit
      }
    } catch {
      if ($_.Exception.InnerException) {
        Write-Host -object $_.Exception.InnerException.Message -ForegroundColor DarkYellow
      }
      Write-Host -object $_.Exception.Message -ForegroundColor Red
      throw
    }
    $driver_target = (Join-Path -Path $work_dir -ChildPath $driver.target)
    if (Test-Path -Path $driver_target -ErrorAction SilentlyContinue) {
      Remove-Item $driver_target -Force -Recurse
      Write-Host -object ('deleted: {0}' -f $driver_target) -ForegroundColor DarkGray
    }
    try {
      if ($driver.extract) {
        $ext = [System.IO.Path]::GetExtension($local_path)
        if ($ext -ne '.zip') {
          $local_path_as_zip = $local_path.Remove(($lastIndex = $local_path.LastIndexOf($ext)), $ext.Length).Insert($lastIndex, '.zip')
          Rename-Item -Path $local_path -NewName $local_path_as_zip
          $local_path = $local_path_as_zip
        }
        Expand-Archive -Path $local_path -DestinationPath $driver_target
        Write-Host -object ('extracted {0} to {1}' -f (Resolve-Path -Path $local_path), (Resolve-Path -Path $driver_target)) -ForegroundColor White
        if ($ext -ne '.zip') {
          $local_path_as_ext = $local_path.Remove(($lastIndex = $local_path.LastIndexOf('.zip')), '.zip'.Length).Insert($lastIndex, $ext)
          Rename-Item -Path $local_path -NewName $local_path_as_ext
        }
      } else {
        Copy-Item -Path (Resolve-Path -Path $local_path) -Destination $driver_target
        Write-Host -object ('copied {0} to {1}' -f (Resolve-Path -Path $local_path), (Resolve-Path -Path $driver_target)) -ForegroundColor White
      }
    } catch {
      if ($_.Exception.InnerException) {
        Write-Host -object $_.Exception.InnerException.Message -ForegroundColor DarkYellow
      }
      Write-Host -object $_.Exception.Message -ForegroundColor Red
      throw
    }
    $drivers += (Resolve-Path -Path (Join-Path -Path $work_dir -ChildPath $driver.inf)).Path
  }

  # delete the vhd(x) file if it exists
  if (Test-Path -Path $vhd_path -ErrorAction SilentlyContinue) {
    Remove-Item -Path $vhd_path -Force
  }
  # create the vhd(x) file
  try {
    . (Join-Path -Path $work_dir -ChildPath 'Convert-WindowsImage.ps1')
    $disableWindowsService = $(if ($config.service -and $config.service.disable -and $config.service.disable.Length) { $config.service.disable } else { @() })
    if ($drivers.length) {
      if ($config.architecture.Contains('arm')) {
        Convert-WindowsImage -verbose:$true -SourcePath $iso_path -VhdPath $vhd_path -VhdFormat $config.format -VhdPartitionStyle $config.partition -Edition $(if ($config.wimindex) { $config.wimindex } else { $config.edition }) -UnattendPath (Resolve-Path -Path $ua_path).Path -Driver $drivers -RemoteDesktopEnable:$true -DisableWindowsService $disableWindowsService -DisableNotificationCenter:($config.build.major -eq 10) -BCDBoot ('{0}\System32\bcdboot.exe' -f $env:SystemRoot)
      } else {
        Convert-WindowsImage -verbose:$true -SourcePath $iso_path -VhdPath $vhd_path -VhdFormat $config.format -VhdPartitionStyle $config.partition -Edition $(if ($config.wimindex) { $config.wimindex } else { $config.edition }) -UnattendPath (Resolve-Path -Path $ua_path).Path -Driver $drivers -RemoteDesktopEnable:$true -DisableWindowsService $disableWindowsService -DisableNotificationCenter:($config.build.major -eq 10)
      }
    } else {
      if ($config.architecture.Contains('arm')) {
        Convert-WindowsImage -verbose:$true -SourcePath $iso_path -VhdPath $vhd_path -VhdFormat $config.format -VhdPartitionStyle $config.partition -Edition $(if ($config.wimindex) { $config.wimindex } else { $config.edition }) -UnattendPath (Resolve-Path -Path $ua_path).Path -RemoteDesktopEnable:$true -DisableWindowsService $disableWindowsService -DisableNotificationCenter:($config.build.major -eq 10) -BCDBoot ('{0}\System32\bcdboot.exe' -f $env:SystemRoot)
      } else {
        Convert-WindowsImage -verbose:$true -SourcePath $iso_path -VhdPath $vhd_path -VhdFormat $config.format -VhdPartitionStyle $config.partition -Edition $(if ($config.wimindex) { $config.wimindex } else { $config.edition }) -UnattendPath (Resolve-Path -Path $ua_path).Path -RemoteDesktopEnable:$true -DisableWindowsService $disableWindowsService -DisableNotificationCenter:($config.build.major -eq 10)
      }
    }
    if (Test-Path -Path $vhd_path -ErrorAction SilentlyContinue) {
      Write-Host -object ('created {0} from {1}' -f $vhd_path, $iso_path) -ForegroundColor White
    } else {
      Write-Host -object ('failed to create {0} from {1}' -f $vhd_path, $iso_path) -ForegroundColor Red
    }
  } catch {
    if ($_.Exception.InnerException) {
      Write-Host -object $_.Exception.InnerException.Message -ForegroundColor DarkYellow
    }
    Write-Host -object $_.Exception.Message -ForegroundColor Red
    throw
  }

  # mount the vhd and create a temp directory
  $mount_path = (Join-Path -Path $pwd -ChildPath ([System.Guid]::NewGuid().Guid.Substring(28)))
  New-Item -Path $mount_path -ItemType directory -force
  if (Test-Path -Path $mount_path -ErrorAction SilentlyContinue) {
    Write-Host -object ('created mount point: {0}' -f (Resolve-Path -Path $mount_path)) -ForegroundColor White
  } else {
    Write-Host -object ('failed to creat mount point: {0}' -f $mount_path) -ForegroundColor Red
  }
  try {
    Mount-WindowsImage -ImagePath $vhd_path -Path $mount_path -Index 1
    Write-Host -object ('mounted: {0} at mount point: {1}' -f $vhd_path, $mount_path) -ForegroundColor White
  } catch {
    if ($_.Exception.InnerException) {
      Write-Host -object $_.Exception.InnerException.Message -ForegroundColor DarkYellow
    }
    Write-Host -object $_.Exception.Message -ForegroundColor Red
    Dismount-WindowsImage -Path $mount_path -Save
    throw
  }


  # download package files if not on the local filesystem
  foreach ($package in @($config.packages | ? { ((-not $_.key.Contains('EC2')) -and (-not $_.key.Contains('Ec2')) -and (-not $_.key.Contains('WallpaperSettings'))) })) {
    $local_path = (Join-Path -Path $work_dir -ChildPath ([System.IO.Path]::GetFileName($package.key)))
    if (-not (Test-Path -Path $local_path -ErrorAction SilentlyContinue)) {
      try {
        if (Get-Command 'Read-GcsObject' -ErrorAction 'SilentlyContinue') {
          Write-Host -object ('downloading {0} from bucket {1} with key {2}' -f $local_path, $package.bucket, $package.key) -ForegroundColor White
          Read-GcsObject -Bucket $package.bucket -ObjectName $package.key -OutFile $local_path
        }
        if (Test-Path -Path $local_path -ErrorAction SilentlyContinue) {
          Write-Host -object ('downloaded {0} from bucket {1} with key {2}' -f (Resolve-Path -Path $local_path), $package.bucket, $package.key) -ForegroundColor White
        } else {
          Write-Host -object ('failed to download {0} from bucket {1} with key {2}' -f $local_path, $package.bucket, $package.key) -ForegroundColor Red
        }
      } catch {
        if ($_.Exception.InnerException) {
          Write-Host -object $_.Exception.InnerException.Message -ForegroundColor DarkYellow
        }
        Write-Host -object $_.Exception.Message -ForegroundColor Red
        throw
      }
    } else {
      Write-Host -object ('package file detected at: {0}' -f (Resolve-Path -Path $local_path)) -ForegroundColor DarkGray
    }
    $mount_path_package_target = (Join-Path -Path $mount_path -ChildPath $package.target)
    try {
      if ($package.extract) {
        Expand-Archive -Path $local_path -DestinationPath $mount_path_package_target
        Write-Host -object ('extracted {0} to {1}' -f (Resolve-Path -Path $local_path), (Resolve-Path -Path $mount_path_package_target)) -ForegroundColor White
      } else {
        Copy-Item -Path (Resolve-Path -Path $local_path) -Destination $mount_path_package_target
        Write-Host -object ('copied {0} to {1}' -f (Resolve-Path -Path $local_path), (Resolve-Path -Path $mount_path_package_target)) -ForegroundColor White
      }
    } catch {
      if ($_.Exception.InnerException) {
        Write-Host -object $_.Exception.InnerException.Message -ForegroundColor DarkYellow
      }
      Write-Host -object $_.Exception.Message -ForegroundColor Red
      throw
    }
  }
  # dismount the vhd, save it and remove the mount point
  try {
    Dismount-WindowsImage -Path $mount_path -Save
    Write-Host -object ('dismount of {0} from {1} complete' -f $vhd_path, $mount_path) -ForegroundColor White
    Remove-Item -Path $mount_path -Force
  } catch {
    if ($_.Exception.InnerException) {
      Write-Host -object $_.Exception.InnerException.Message -ForegroundColor DarkYellow
    }
    Write-Host -object $_.Exception.Message -ForegroundColor Red
    throw
  }

  # upload the vhd(x) file
  try {
    New-GcsObject -Bucket $config.vhd.bucket -File $vhd_path -ObjectName $vhd_key
    Write-Host -object ('uploaded {0} to bucket {1} with key {2}' -f $vhd_path, $config.vhd.bucket, $vhd_key) -ForegroundColor White
  } catch {
    Write-Host -object ('failed to upload {0} to bucket {1}' -f $config.vhd.bucket, $vhd_key) -ForegroundColor Red
    if ($_.Exception.InnerException) {
      Write-Host -object $_.Exception.InnerException.Message -ForegroundColor DarkYellow
    }
    Write-Host -object $_.Exception.Message -ForegroundColor Red
  }
} else {
  Write-Host -object ('vhd exists in bucket {0} with key {1}. skipping vhd creation.' -f $config.vhd.bucket, $vhd_key) -ForegroundColor White
}

# use cloud build to import the vhd as a gcp image
$familyVersion = $(if ($config.version -eq 1903) { 10 } else { $(if ($config.version -eq 2012) { '2012r2' } else { $config.version }) })
& gcloud @('beta', 'compute', 'images', 'import',
  ('windows-{0}-{1}' -f $familyVersion, $source_ref.SubString(0, 7)),
  '--source-file', ('gs://{0}/{1}' -f $config.vhd.bucket, $vhd_key),
  '--project', 'image-builder-242310',
  '--family', ('windows-{0}' -f $familyVersion),
  '--os', ('windows-{0}-byol' -f $familyVersion))

& gcloud @('compute', 'images', 'add-labels',
  ('windows-{0}-{1}' -f $familyVersion, $source_ref.SubString(0, 7)),
  '--project', 'image-builder-242310',
  '--labels', ('os-edition={0},os-architecture={1},occ-version={2}' -f $config.edition.ToLower(), $(if ($config.architecture -eq 'x64') { 'x86-64' } else { 'x86' }), $source_ref.SubString(0, 7)))
