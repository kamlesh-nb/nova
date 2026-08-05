using System; using System.Security.Cryptography;
class MB {
  static bool InSet(double cr, double ci) {
    double zr=0, zi=0, tr=0, ti=0;
    for (int o=0;o<10;o++) for (int j=0;j<5;j++) {
      double nzi = 2.0*zr*zi + ci;
      double nzr = (tr - ti) + cr;
      zr = nzr; zi = nzi;
      tr = zr*zr; ti = zi*zi;
    }
    return tr+ti <= 4.0;
  }
  static void Main(string[] args) {
    int size = args.Length>0 ? int.Parse(args[0]) : 200;
    size = (size+7)/8*8;
    int w = size/8;
    double inv = 2.0/size;
    var pixels = new byte[size*w];
    for (int py=0; py<size; py++) {
      double ci = py*inv - 1.0;
      for (int bx=0; bx<w; bx++) {
        int accu = 0;
        for (int lane=0; lane<8; lane++) {
          double cr = (bx*8+lane)*inv - 1.5;
          if (InSet(cr, ci)) accu |= 0x80 >> lane;
        }
        pixels[py*w+bx] = (byte)accu;
      }
    }
    Console.WriteLine($"P4\n{size} {size}");
    var h = MD5.HashData(pixels);
    Console.WriteLine(Convert.ToHexString(h).ToLowerInvariant());
  }
}
