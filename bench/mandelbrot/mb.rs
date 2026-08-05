fn in_set(cr: f64, ci: f64) -> bool {
    let (mut zr, mut zi, mut tr, mut ti) = (0.0f64, 0.0, 0.0, 0.0);
    for _ in 0..10 { for _ in 0..5 {
        let nzi = 2.0*zr*zi + ci;
        let nzr = (tr - ti) + cr;
        zr = nzr; zi = nzi;
        tr = zr*zr; ti = zi*zi;
    }}
    tr + ti <= 4.0
}
fn main() {
    let mut size: usize = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(200);
    size = (size + 7) / 8 * 8;
    let w = size / 8;
    let inv = 2.0 / size as f64;
    let mut pixels = vec![0u8; size*w];
    for py in 0..size {
        let ci = py as f64 * inv - 1.0;
        for bx in 0..w {
            let mut accu = 0u8;
            for lane in 0..8 {
                let cr = (bx*8+lane) as f64 * inv - 1.5;
                if in_set(cr, ci) { accu |= 0x80u8 >> lane; }
            }
            pixels[py*w+bx] = accu;
        }
    }
    println!("P4\n{} {}", size, size);
    let d = md5mod::compute(&pixels);
    for byte in d.iter() { print!("{:02x}", byte); } println!();
}
