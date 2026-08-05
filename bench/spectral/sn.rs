fn evala(i: usize, j: usize) -> f64 { (((i + j) * (i + j + 1) / 2 + i + 1) as f64) }
fn times(v: &mut [f64], u: &[f64]) {
    for i in 0..v.len() { let mut a = 0.0; for j in 0..u.len() { a += u[j] / evala(i, j); } v[i] = a; }
}
fn times_trans(v: &mut [f64], u: &[f64]) {
    for i in 0..v.len() { let mut a = 0.0; for j in 0..u.len() { a += u[j] / evala(j, i); } v[i] = a; }
}
fn a_times_transp(v: &mut [f64], u: &[f64], x: &mut [f64]) { times(x, u); times_trans(v, x); }
fn main() {
    let n: usize = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(100);
    let mut u = vec![1.0f64; n]; let mut v = vec![1.0f64; n]; let mut x = vec![0.0f64; n];
    for _ in 0..10 { a_times_transp(&mut v, &u, &mut x); a_times_transp(&mut u, &v, &mut x); }
    let (mut vbv, mut vv) = (0.0, 0.0);
    for i in 0..n { vbv += u[i]*v[i]; vv += v[i]*v[i]; }
    println!("{:.9}", (vbv/vv).sqrt());
}
