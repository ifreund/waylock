use std::num::ParseIntError;

#[derive(Copy, Clone)]
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

    pub fn is_valid(hex_str: String) -> Result<(), String> {
        if hex_str.len() != 6 {
            Err("COLOR arg must be exactly 6 digits".to_owned())
        } else if let Err(e) = u32::from_str_radix(&hex_str, 16) {
            Err(format!("{}", e))
        } else {
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_6_digit_color_valid() {
        assert!(Color::is_valid("01abEF".to_owned()).is_ok());
    }

    #[test]
    fn short_color_invalid() {
        assert!(Color::is_valid("12345".to_owned()).is_err());
    }

    #[test]
    fn long_color_invalid() {
        assert!(Color::is_valid("1234567".to_owned()).is_err());
    }

    #[test]
    fn non_hex_color_invalid() {
        assert!(Color::is_valid("12z456".to_owned()).is_err());
    }
}
