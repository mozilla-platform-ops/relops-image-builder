$iso_url='https://software-download.microsoft.com/pr/Win10_1803_EnglishInternational_x64.iso?t=080ddbfb-902c-4c57-beb8-bc1c57378ed5&e=1531303905&h=265b8b68c521570bc0fb860c7a5f3590'
$iso_path='Z:\Win10_1803_EnglishInternational_x64.iso'
$vhd_path='Z:\Win10_1803_EnglishInternational_x64.vhd'
(New-Object Net.WebClient).DownloadFile($iso_url, $iso_path)
(New-Object Net.WebClient).DownloadFile('https://raw.githubusercontent.com/mozilla-platform-ops/relops_image_builder/master/Convert-WindowsImage.ps1', 'Z:\Convert-WindowsImage.ps1')
. Z:\Convert-WindowsImage.ps1
Convert-WindowsImage -SourcePath $iso_path -VHDPath $vhd_path