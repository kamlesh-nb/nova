using System;
class FK {
  static (int,int) Fannkuch(int n) {
    int[] perm = new int[n], perm1 = new int[n], count = new int[n];
    for (int i=0;i<n;i++) perm1[i]=i;
    int r=n, maxFlips=0, checksum=0, permIndex=0;
    while (true) {
      while (r!=1){ count[r-1]=r; r--; }
      Array.Copy(perm1, perm, n);
      int flips=0, k=perm[0];
      while (k!=0){ for(int lo=0,hi=k;lo<hi;lo++,hi--){ int t=perm[lo];perm[lo]=perm[hi];perm[hi]=t; } flips++; k=perm[0]; }
      if (flips>maxFlips) maxFlips=flips;
      checksum += (permIndex%2==0)?flips:-flips;
      bool done=false;
      while (true) {
        if (r==n){ done=true; break; }
        int p0=perm1[0]; for(int m=0;m<r;m++) perm1[m]=perm1[m+1]; perm1[r]=p0;
        count[r]--; if (count[r]>0) break; r++;
      }
      if (done) break;
      permIndex++;
    }
    return (checksum, maxFlips);
  }
  static void Main(string[] a){ int n=a.Length>0?int.Parse(a[0]):7; var (c,m)=Fannkuch(n); Console.WriteLine($"{c}\nPfannkuchen({n}) = {m}"); }
}
