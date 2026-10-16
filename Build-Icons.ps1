param([string]$OutputDirectory=(Join-Path $PSScriptRoot 'build'))
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
if(-not ('FolderLock.BrandIcons' -as [type])) {
Add-Type -ReferencedAssemblies System.Drawing,System.Xml -TypeDefinition @'
using System;
using System.IO;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Xml;
using System.Text.RegularExpressions;
using System.Globalization;
namespace FolderLock {
public static class BrandIcons {
    // Intentionally a small renderer for our trusted, path-only SVG source assets.
    public static Bitmap Render(string source, int size) {
        var doc = new XmlDocument(); doc.XmlResolver = null; doc.Load(source);
        float basis = Single.Parse(doc.DocumentElement.GetAttribute("viewBox").Split(' ')[2], CultureInfo.InvariantCulture);
        using(var high = new Bitmap(size*4,size*4,PixelFormat.Format32bppArgb)) {
            using(var g=Graphics.FromImage(high)) {
                g.Clear(Color.Transparent); g.SmoothingMode=SmoothingMode.AntiAlias; g.ScaleTransform(size*4/basis,size*4/basis);
                foreach(XmlNode node in doc.DocumentElement.ChildNodes) {
                    var element=node as XmlElement; if(element==null || element.LocalName!="path")continue;
                    var tokens=Regex.Matches(element.GetAttribute("d"), @"[MLCZ]|-?\d+(?:\.\d+)?"); int i=0; float x=0,y=0;
                    using(var p=new GraphicsPath()) {
                        while(i<tokens.Count) {
                            string command=tokens[i++].Value;
                            if(command=="Z") {p.CloseFigure();continue;}
                            int count=command=="C"?6:2; var v=new float[count];
                            for(int n=0;n<count;n++)v[n]=Single.Parse(tokens[i++].Value,CultureInfo.InvariantCulture);
                            if(command=="M")p.StartFigure();
                            else if(command=="L")p.AddLine(x,y,v[0],v[1]);
                            else if(command=="C")p.AddBezier(x,y,v[0],v[1],v[2],v[3],v[4],v[5]);
                            else throw new InvalidDataException("Unsupported SVG command");
                            x=v[count-2];y=v[count-1];
                        }
                        using(var brush=new SolidBrush(ColorTranslator.FromHtml(element.GetAttribute("fill"))))g.FillPath(brush,p);
                    }
                }
            }
            var result=new Bitmap(size,size,PixelFormat.Format32bppArgb);
            using(var g=Graphics.FromImage(result)){g.CompositingMode=CompositingMode.SourceCopy;g.InterpolationMode=InterpolationMode.HighQualityBicubic;g.DrawImage(high,new Rectangle(0,0,size,size),0,0,high.Width,high.Height,GraphicsUnit.Pixel);}
            return result;
        }
    }
    public static byte[] Frame(Bitmap image, bool png) {
        using(var stream=new MemoryStream()) {
            if(png)image.Save(stream,ImageFormat.Png);
            else using(var writer=new BinaryWriter(stream,System.Text.Encoding.UTF8,true)) {
                int size=image.Width, stride=((size+31)/32)*4;
                writer.Write(40);writer.Write(size);writer.Write(size*2);writer.Write((short)1);writer.Write((short)32);
                writer.Write(0);writer.Write(size*size*4);writer.Write(0);writer.Write(0);writer.Write(0);writer.Write(0);
                for(int y=size-1;y>=0;y--)for(int x=0;x<size;x++){var c=image.GetPixel(x,y);writer.Write(c.B);writer.Write(c.G);writer.Write(c.R);writer.Write(c.A);}
                for(int y=size-1;y>=0;y--){var row=new byte[stride];for(int x=0;x<size;x++)if(image.GetPixel(x,y).A==0)row[x/8]|=(byte)(128>>(x%8));writer.Write(row);}
            }
            return stream.ToArray();
        }
    }
}
}
'@
}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$sizes=@(16,20,24,32,40,48,64,96,128,256)
$frames=New-Object 'System.Collections.Generic.List[byte[]]'
foreach($size in $sizes) {
    $source=Join-Path $PSScriptRoot $(if($size -le 24){'assets\FolderLock-small.svg'}else{'assets\FolderLock.svg'})
    $image=[FolderLock.BrandIcons]::Render($source,$size)
    try {$image.Save((Join-Path $OutputDirectory "FolderLock-$size.png"),[Drawing.Imaging.ImageFormat]::Png);$frames.Add([FolderLock.BrandIcons]::Frame($image,($size -eq 256)))} finally {$image.Dispose()}
}
$writer=[IO.BinaryWriter]::new([IO.File]::Create((Join-Path $OutputDirectory 'FolderLock.ico')))
try {
    $writer.Write([uint16]0);$writer.Write([uint16]1);$writer.Write([uint16]$sizes.Count)
    $offset=6+16*$sizes.Count
    for($i=0;$i -lt $sizes.Count;$i++) {
        $dimension=[byte]$(if($sizes[$i] -eq 256){0}else{$sizes[$i]})
        $writer.Write($dimension);$writer.Write($dimension);$writer.Write([byte]0);$writer.Write([byte]0)
        $writer.Write([uint16]1);$writer.Write([uint16]32);$writer.Write([uint32]$frames[$i].Length);$writer.Write([uint32]$offset)
        $offset+=$frames[$i].Length
    }
    foreach($frame in $frames){$writer.Write([byte[]]$frame)}
} finally {$writer.Dispose()}
# A review sheet shows the real menu sizes against both Explorer themes.
$logo=[FolderLock.BrandIcons]::Render((Join-Path $PSScriptRoot 'assets\FolderLock.svg'),1024)
try {$logo.Save((Join-Path $OutputDirectory 'FolderLock-logo.png'),[Drawing.Imaging.ImageFormat]::Png)} finally {$logo.Dispose()}
$board=[Drawing.Bitmap]::new(960,440);$g=[Drawing.Graphics]::FromImage($board)
$font=[Drawing.Font]::new('Segoe UI',10);$brandFont=[Drawing.Font]::new('Segoe UI Semibold',35)
try {
    $g.Clear([Drawing.Color]::White)
    $navy=[Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#12384B'))
    $dark=[Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#20272D'))
    try {
        $large=[FolderLock.BrandIcons]::Render((Join-Path $PSScriptRoot 'assets\FolderLock.svg'),160)
        try {$g.DrawImageUnscaled($large,32,20)}finally{$large.Dispose()}
        $g.DrawString('FolderLock',$brandFont,$navy,208,58)
        $g.DrawString('Encrypted folders. Familiar paths.',$font,$navy,212,123)
        $g.FillRectangle($dark,0,304,960,136)
        $g.DrawString('EXPLORER / LIGHT',$font,$navy,32,188)
        $g.DrawString('EXPLORER / DARK',$font,[Drawing.Brushes]::White,32,320)
        $x=32
        foreach($size in @(16,20,24,32,40,48,64)) {
            $img=[Drawing.Image]::FromFile((Join-Path $OutputDirectory "FolderLock-$size.png"))
            try {$g.DrawImageUnscaled($img,$x,224);$g.DrawImageUnscaled($img,$x,354)} finally {$img.Dispose()}
            $g.DrawString([string]$size,$font,$navy,$x+70,236)
            $g.DrawString([string]$size,$font,[Drawing.Brushes]::White,$x+70,366)
            $x+=130
        }
    } finally {$navy.Dispose();$dark.Dispose()}
    $board.Save((Join-Path $OutputDirectory 'FolderLock-brand-preview.png'),[Drawing.Imaging.ImageFormat]::Png)
} finally {$font.Dispose();$brandFont.Dispose();$g.Dispose();$board.Dispose()}
