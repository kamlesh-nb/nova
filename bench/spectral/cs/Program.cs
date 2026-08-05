using System; using System.Globalization;
class SN {
  static double EvalA(int i, int j) => (i + j) * (i + j + 1) / 2 + i + 1;
  static void Times(double[] v, double[] u) {
    for (int i = 0; i < v.Length; i++) { double a = 0; for (int j = 0; j < u.Length; j++) a += u[j] / EvalA(i, j); v[i] = a; } }
  static void TimesTrans(double[] v, double[] u) {
    for (int i = 0; i < v.Length; i++) { double a = 0; for (int j = 0; j < u.Length; j++) a += u[j] / EvalA(j, i); v[i] = a; } }
  static void ATimesTransp(double[] v, double[] u, double[] x) { Times(x, u); TimesTrans(v, x); }
  static void Main(string[] args) {
    int n = args.Length > 0 ? int.Parse(args[0]) : 100;
    double[] u = new double[n], v = new double[n], x = new double[n];
    for (int i = 0; i < n; i++) { u[i] = 1; v[i] = 1; }
    for (int k = 0; k < 10; k++) { ATimesTransp(v, u, x); ATimesTransp(u, v, x); }
    double vbv = 0, vv = 0;
    for (int i = 0; i < n; i++) { vbv += u[i]*v[i]; vv += v[i]*v[i]; }
    Console.WriteLine(Math.Sqrt(vbv/vv).ToString("f9", CultureInfo.InvariantCulture));
  }
}
