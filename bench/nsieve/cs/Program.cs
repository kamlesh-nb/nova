using System;
class NS {
  static int Sieve(bool[] flags, int m) {
    for (int i=0;i<m;i++) flags[i]=true;
    int count=0;
    for (int i=2;i<m;i++) if (flags[i]) { count++; for (int j=i+i;j<m;j+=i) flags[j]=false; }
    return count;
  }
  static void Main(string[] a) {
    int n = a.Length>0?int.Parse(a[0]):4; int reps=400, max=10000<<n; var flags=new bool[max];
    int x=0,y=0,z=0;
    for (int r=0;r<reps;r++){ x=Sieve(flags,10000<<n); y=Sieve(flags,10000<<(n-1)); z=Sieve(flags,10000<<(n-2)); }
    Console.WriteLine($"Primes up to {10000<<n,8} {x,8}");
    Console.WriteLine($"Primes up to {10000<<(n-1),8} {y,8}");
    Console.WriteLine($"Primes up to {10000<<(n-2),8} {z,8}");
  }
}
