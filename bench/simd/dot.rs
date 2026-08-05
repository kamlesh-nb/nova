fn main() {
    let a = vec![1.0f64; 4096]; let b = vec![2.0f64; 4096];
    let mut acc = 0.0;
    for _ in 0..100000 {
        let mut s = 0.0; for i in 0..4096 { s += a[i]*b[i]; }
        acc += s;
    }
    println!("{}", acc);
}
