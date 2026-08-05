struct Node { left: Option<Box<Node>>, right: Option<Box<Node>> }
fn bottom_up(depth: i32) -> Box<Node> {
    if depth <= 0 { Box::new(Node{left:None,right:None}) }
    else { Box::new(Node{left:Some(bottom_up(depth-1)), right:Some(bottom_up(depth-1))}) }
}
fn item_check(n: &Node) -> i32 {
    match &n.left { None => 1, Some(l) => 1 + item_check(l) + item_check(n.right.as_ref().unwrap()) }
}
const MIN_DEPTH: i32 = 4;
fn main() {
    let max_depth = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(10).max(MIN_DEPTH+2);
    let stretch = max_depth + 1;
    println!("stretch tree of depth {}\t check: {}", stretch, item_check(&bottom_up(stretch)));
    let long_lived = bottom_up(max_depth);
    let mut depth = MIN_DEPTH;
    while depth <= max_depth {
        let iterations = 1i32 << (max_depth - depth + MIN_DEPTH);
        let mut check = 0;
        for _ in 1..=iterations { check += item_check(&bottom_up(depth)); }
        println!("{}\t trees of depth {}\t check: {}", iterations, depth, check);
        depth += 2;
    }
    println!("long lived tree of depth {}\t check: {}", max_depth, item_check(&long_lived));
}
