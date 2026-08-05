using System;
class Node { public Node left, right; }
class BT {
  static Node BottomUp(int d) => d<=0 ? new Node() : new Node{left=BottomUp(d-1), right=BottomUp(d-1)};
  static int ItemCheck(Node n) => n.left==null ? 1 : 1 + ItemCheck(n.left) + ItemCheck(n.right);
  const int MinDepth=4;
  static void Main(string[] a){
    int maxDepth = Math.Max(MinDepth+2, a.Length>0?int.Parse(a[0]):10);
    int stretch = maxDepth+1;
    Console.WriteLine($"stretch tree of depth {stretch}\t check: {ItemCheck(BottomUp(stretch))}");
    var longLived = BottomUp(maxDepth);
    for (int depth=MinDepth; depth<=maxDepth; depth+=2){
      int iterations = 1 << (maxDepth-depth+MinDepth); int check=0;
      for (int i=1;i<=iterations;i++) check += ItemCheck(BottomUp(depth));
      Console.WriteLine($"{iterations}\t trees of depth {depth}\t check: {check}");
    }
    Console.WriteLine($"long lived tree of depth {maxDepth}\t check: {ItemCheck(longLived)}");
  }
}
