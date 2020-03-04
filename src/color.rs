use std::num::ParseIntError;

#[derive(Copy,Clone)]
pub struct Color {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
}

impl Color {
    pub fn new_from_hex_str(hex_str: &str) -> Result<Self, ParseIntError> {
        let hex = u32::from_str_radix(hex_str, 16)?;
        Ok(Self {
            red: (hex / (256 * 256)) as f64 / 255.0,
            green: (hex / 256 % 256) as f64 / 255.0,
            blue: (hex % 256) as f64 / 255.0,
        })
    }
}
