// Scalar N-body (Computer Language Benchmarks Game), faithful to the reference Go 1.go algorithm.
// Portable (no x86 AVX intrinsics), so it runs on arm64 and is apples-to-apples with the scalar
// Go/Rust/Kyte versions in this comparison.
using System;
using System.Globalization;

class NBody {
    const double SolarMass = 4.0 * Math.PI * Math.PI;
    const double DaysPerYear = 365.24;

    class Body { public double x, y, z, vx, vy, vz, mass; }

    static Body[] NewSystem() {
        var b = new Body[] {
            new Body { mass = SolarMass },
            new Body { x=4.84143144246472090e+00, y=-1.16032004402742839e+00, z=-1.03622044471123109e-01,
                vx=1.66007664274403694e-03*DaysPerYear, vy=7.69901118419740425e-03*DaysPerYear, vz=-6.90460016972063023e-05*DaysPerYear,
                mass=9.54791938424326609e-04*SolarMass },
            new Body { x=8.34336671824457987e+00, y=4.12479856412430479e+00, z=-4.03523417114321381e-01,
                vx=-2.76742510726862411e-03*DaysPerYear, vy=4.99852801234917238e-03*DaysPerYear, vz=2.30417297573763929e-05*DaysPerYear,
                mass=2.85885980666130812e-04*SolarMass },
            new Body { x=1.28943695621391310e+01, y=-1.51111514016986312e+01, z=-2.23307578892655734e-01,
                vx=2.96460137564761618e-03*DaysPerYear, vy=2.37847173959480950e-03*DaysPerYear, vz=-2.96589568540237556e-05*DaysPerYear,
                mass=4.36624404335156298e-05*SolarMass },
            new Body { x=1.53796971148509165e+01, y=-2.59193146099879641e+01, z=1.79258772950371181e-01,
                vx=2.68067772490389322e-03*DaysPerYear, vy=1.62824170038242295e-03*DaysPerYear, vz=-9.51592254519715870e-05*DaysPerYear,
                mass=5.15138902046611451e-05*SolarMass },
        };
        double px=0, py=0, pz=0;
        foreach (var bo in b) { px += bo.vx*bo.mass; py += bo.vy*bo.mass; pz += bo.vz*bo.mass; }
        b[0].vx = -px/SolarMass; b[0].vy = -py/SolarMass; b[0].vz = -pz/SolarMass;
        return b;
    }

    static double Energy(Body[] s) {
        double e = 0;
        for (int i = 0; i < s.Length; i++) {
            var bi = s[i];
            e += 0.5 * bi.mass * (bi.vx*bi.vx + bi.vy*bi.vy + bi.vz*bi.vz);
            for (int j = i+1; j < s.Length; j++) {
                var bj = s[j];
                double dx = bi.x-bj.x, dy = bi.y-bj.y, dz = bi.z-bj.z;
                e -= (bi.mass*bj.mass) / Math.Sqrt(dx*dx+dy*dy+dz*dz);
            }
        }
        return e;
    }

    static void Advance(Body[] s, double dt) {
        for (int i = 0; i < s.Length; i++) {
            var bi = s[i];
            double vx = bi.vx, vy = bi.vy, vz = bi.vz;
            for (int j = i+1; j < s.Length; j++) {
                var bj = s[j];
                double dx = bi.x-bj.x, dy = bi.y-bj.y, dz = bi.z-bj.z;
                double d2 = dx*dx+dy*dy+dz*dz;
                double dist = Math.Sqrt(d2);
                double mag = dt / (d2*dist);
                vx -= dx*bj.mass*mag; vy -= dy*bj.mass*mag; vz -= dz*bj.mass*mag;
                bj.vx += dx*bi.mass*mag; bj.vy += dy*bi.mass*mag; bj.vz += dz*bi.mass*mag;
            }
            bi.vx = vx; bi.vy = vy; bi.vz = vz;
            bi.x += dt*vx; bi.y += dt*vy; bi.z += dt*vz;
        }
    }

    static void Main(string[] args) {
        int n = args.Length > 0 ? int.Parse(args[0]) : 1000;
        var s = NewSystem();
        Console.WriteLine(Energy(s).ToString("F9", CultureInfo.InvariantCulture));
        for (int i = 0; i < n; i++) Advance(s, 0.01);
        Console.WriteLine(Energy(s).ToString("F9", CultureInfo.InvariantCulture));
    }
}
