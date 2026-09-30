//! A fixed-capacity ring (the newest `cap` items; pushing past it drops the oldest).
//! Allocated once; `push` never allocates.

#[derive(Debug, Clone)]
pub struct Ring<T: Copy + Default> {
    buf: Vec<T>,
    head: usize,
    len: usize,
}

impl<T: Copy + Default> Ring<T> {
    pub fn new(cap: usize) -> Self {
        Self {
            buf: vec![T::default(); cap.max(1)],
            head: 0,
            len: 0,
        }
    }

    pub fn cap(&self) -> usize {
        self.buf.len()
    }

    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    pub fn clear(&mut self) {
        self.head = 0;
        self.len = 0;
    }

    /// Adds the newest item; returns the one it pushed out, if any.
    pub fn push(&mut self, x: T) -> Option<T> {
        let cap = self.buf.len();
        let slot = (self.head + self.len) % cap;
        if self.len == cap {
            let old = self.buf[self.head];
            self.buf[self.head] = x;
            self.head = (self.head + 1) % cap;
            Some(old)
        } else {
            self.buf[slot] = x;
            self.len += 1;
            None
        }
    }

    /// The k-th oldest item.
    pub fn get(&self, k: usize) -> Option<&T> {
        (k < self.len).then(|| &self.buf[(self.head + k) % self.buf.len()])
    }

    pub fn get_mut(&mut self, k: usize) -> Option<&mut T> {
        let cap = self.buf.len();
        (k < self.len).then(|| &mut self.buf[(self.head + k) % cap])
    }

    /// Oldest first.
    pub fn iter(&self) -> impl DoubleEndedIterator<Item = &T> + '_ {
        (0..self.len).map(move |k| &self.buf[(self.head + k) % self.buf.len()])
    }

    /// Drops the `n` newest items.
    pub fn truncate_back(&mut self, n: usize) {
        self.len -= n.min(self.len);
    }

    /// Drops the `n` oldest items.
    pub fn drop_front(&mut self, n: usize) {
        let n = n.min(self.len);
        self.head = (self.head + n) % self.buf.len();
        self.len -= n;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_the_newest() {
        let mut r: Ring<u32> = Ring::new(3);
        assert!(r.push(1).is_none());
        r.push(2);
        r.push(3);
        assert_eq!(r.push(4), Some(1));
        assert_eq!(r.iter().copied().collect::<Vec<_>>(), [2, 3, 4]);
        assert_eq!(r.get(0), Some(&2));
        *r.get_mut(2).unwrap() = 9;
        r.drop_front(1);
        assert_eq!(r.iter().copied().collect::<Vec<_>>(), [3, 9]);
        r.clear();
        assert!(r.is_empty());
    }
}
