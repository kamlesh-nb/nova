fn fannkuch(n: usize) -> (i32, i32) {
    let mut perm = vec![0usize; n]; let mut perm1: Vec<usize> = (0..n).collect(); let mut count = vec![0usize; n];
    let mut r = n; let mut max_flips = 0i32; let mut checksum = 0i32; let mut perm_index = 0i64;
    loop {
        while r != 1 { count[r-1] = r; r -= 1; }
        perm.copy_from_slice(&perm1);
        let mut flips = 0i32; let mut k = perm[0];
        while k != 0 { perm[0..=k].reverse(); flips += 1; k = perm[0]; }
        if flips > max_flips { max_flips = flips; }
        checksum += if perm_index % 2 == 0 { flips } else { -flips };
        let mut done = false;
        loop {
            if r == n { done = true; break; }
            let p0 = perm1[0]; for m in 0..r { perm1[m] = perm1[m+1]; } perm1[r] = p0;
            count[r] -= 1; if count[r] > 0 { break; } r += 1;
        }
        if done { break; }
        perm_index += 1;
    }
    (checksum, max_flips)
}
fn main() {
    let n: usize = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(7);
    let (c, m) = fannkuch(n);
    println!("{}\nPfannkuchen({}) = {}", c, n, m);
}
