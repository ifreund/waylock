use std::{error, fmt, num, str};

#[derive(Debug)]
pub enum ColorError {
    InvalidLength,
    InvalidPrefix,
    ParseInt(num::ParseIntError),
}

impl error::Error for ColorError {
    fn source(&self) -> Option<&(dyn error::Error + 'static)> {
        match self {
            Self::InvalidLength | Self::InvalidPrefix => None,
            Self::ParseInt(err) => err.source(),
        }
    }
}

impl fmt::Display for ColorError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidLength => write!(f, "invalid length, color must have exactly 6 digits"),
            Self::InvalidPrefix => write!(f, "invalid color prefix, must start with '#' or '0x'"),
            Self::ParseInt(err) => write!(f, "parse error: {}", err),
        }
    }
}

#[derive(Copy, Clone)]
pub struct Color {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
}

impl From<u32> for Color {
    fn from(hex: u32) -> Self {
        Self {
            red: f64::from((hex & 0x00ff_0000) >> 16) / 255.0,
            green: f64::from((hex & 0x0000_ff00) >> 8) / 255.0,
            blue: f64::from(hex & 0x0000_00ff) / 255.0,
        }
    }
}

impl str::FromStr for Color {
    type Err = ColorError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let digits = if s.starts_with("0x") {
            &s[2..]
        } else if s.starts_with('#') {
            &s[1..]
        } else {
            return Err(Self::Err::InvalidPrefix);
        };

        if digits.len() != 6 {
            return Err(Self::Err::InvalidLength);
        }

        match u32::from_str_radix(digits, 16) {
            Ok(number) => Ok(Self::from(number)),
            Err(err) => Err(Self::Err::ParseInt(err)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Color, ColorError};
    use std::str::FromStr;

    macro_rules! test {
        ($name: ident: $str: expr, $result: pat) => {
            #[test]
            fn $name() {
                assert!(matches!(Color::from_str($str), $result));
            }
        };
    }

    test!(no_prefix_6_digit: "01abEF", Err(ColorError::InvalidPrefix));
    test!(binary_prefix_6_digit: "0b01abEF", Err(ColorError::InvalidPrefix));
    test!(alphabetic_prefix_6_digit: "a01abEF", Err(ColorError::InvalidPrefix));

    test!(octothorpe_6_digit: "#01abEF", Ok(_));
    test!(octothorpe_short: "#01234", Err(ColorError::InvalidLength));
    test!(octothorpe_long: "#01234567", Err(ColorError::InvalidLength));
    test!(octothorpe_invalid_digit: "#012z45", Err(ColorError::ParseInt(_)));

    test!(hex_6_digit: "#01abEF", Ok(_));
    test!(hex_short: "#01234", Err(ColorError::InvalidLength));
    test!(hex_long: "#01234567", Err(ColorError::InvalidLength));
    test!(hex_invalid_digit: "#012z45", Err(ColorError::ParseInt(_)));
}
