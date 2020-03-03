use pam::Authenticator;
use users::get_current_username;

pub struct LockAuth {
    login: String,
}

impl LockAuth {
    pub fn new() -> Self {
        let login = get_current_username()
            .expect("ERROR: failed to get current username!")
            .into_string()
            .expect("ERROR: failed to parse current username!");
        Self { login }
    }

    /// Attempt to authenticate with PAM. Returns true on success, otherwise false.
    pub fn check_password(&self, password: &str) -> bool {
        let mut authenticator = Authenticator::with_password("system-auth")
            .expect("ERROR: failed to initialize PAM client!");
        authenticator
            .get_handler()
            .set_credentials(&self.login, password);
        match authenticator.authenticate() {
            Ok(()) => true,
            Err(error) => {
                eprintln!("WARNING: authentication failure {}", error);
                false
            }
        }
    }
}
