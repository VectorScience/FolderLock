# FolderLock visual identity

The mark combines the familiar folder silhouette with a closed padlock. It is original vector artwork for this project. No external font, stock illustration, emoji, or icon library is embedded in the mark.

| Role | Colour |
| --- | --- |
| Folder back / keyhole | `#12384B` |
| Folder front | `#187E8D` |
| Lock body | `#A8F0D2` |
| Shackle | `#FFFFFF` |

`FolderLock.svg` is the master. `FolderLock-small.svg` is an optical variant used at 16, 20 and 24 pixels: larger relative lock, thicker details, simplified keyhole. Both have transparent backgrounds and accessible SVG titles. Keep the existing viewBox padding and proportions. Do not squeeze the mark, add lettering inside it, or add a background tile to the shell icon.

Run `Build-Icons.ps1` with Windows PowerShell 5.1 to export a transparent 1024-pixel logo, PNGs, a theme/size review sheet, and a single multi-image ICO. It uses built-in .NET drawing and XML libraries with no network or third-party runtime. Sizes: 16, 20, 24, 32, 40, 48, 64, 96, 128 and 256. Small ICO frames use 32-bit BGRA DIBs and transparency masks; the 256-pixel frame uses PNG compression.

`Build-App.ps1` embeds the ICO in the EXE and script resources and includes `FolderLock-brand-v1.ico` next to the EXE for the Explorer menu and unlock shortcut. The versioned filename distinguishes the new asset from the old cached EXE icon. Keep the entire extracted application together. The normal app restores existing managed unlock shortcuts with the updated icon.

Windows icon sizes follow [Microsoft's icon construction guidance](https://learn.microsoft.com/en-us/windows/apps/design/iconography/app-icon-construction).
