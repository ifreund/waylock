extern fn pam_start(
    service_name: [*:0]const u8,
    user: ?[*:0]const u8,
    conversation: *const Conv,
    pamh: **Handle,
) Result;
pub const start = pam_start;

pub const Handle = opaque {
    extern fn pam_end(
        pamh: *Handle,
        /// Should be set to the result of the last pam library call.
        pam_status: Result,
    ) Result;
    pub const end = pam_end;

    extern fn pam_authenticate(pamh: *Handle, flags: c_int) Result;
    pub const authenticate = pam_authenticate;

    extern fn pam_setcred(pamh: *Handle, flags: c_int) Result;
    pub const setcred = pam_setcred;
};

pub const Message = extern struct {
    msg_style: enum(c_int) {
        prompt_echo_off = 1,
        prompt_echo_on = 2,
        error_msg = 3,
        text_info = 4,
    },
    msg: [*:0]const u8,
};

pub const Response = extern struct {
    resp: [*:0]u8,

    /// From pam_conv(3):
    /// "The resp_retcode member of this struct is unused and should be set to zero."
    resp_retcode: c_int = 0,
};

pub const Conv = extern struct {
    conv: fn (
        num_msg: c_int,
        /// Note: This matches the Linux-PAM API, apparently Solaris PAM differs
        /// in how the msg argument is used.
        msg: [*]*const Message,
        /// Out parameter, the [*]Response array will be free'd using free(3)
        /// by the caller.
        resp: *[*]Response,
        appdata_ptr: ?*anyopaque,
    ) callconv(.C) Result,
    appdata_ptr: ?*anyopaque,
};

pub const Result = enum(c_int) {
    /// Successful function return
    success = 0,
    /// dlopen() failure when dynamically loading a service module
    open_err = 1,
    /// Symbol not found
    symbol_err = 2,
    /// Error in service module
    service_err = 3,
    /// System error
    system_err = 4,
    /// Memory buffer error
    buf_err = 5,
    /// Permission denied
    perm_denied = 6,
    /// Authentication failure
    auth_err = 7,
    /// Can not access authentication data due to insufficient credentials
    cred_insufficient = 8,
    /// Underlying authentication service can not retrieve authentication information
    authinfo_unavail = 9,
    /// User not known to the underlying authentication module
    user_unknown = 10,
    /// An authentication service has maintained a retry count which has
    /// been reached. No further retries should be attempted
    maxtries = 11,
    /// New authentication token required. This is normally returned if the
    /// machine security policies require that the password should be changed
    /// because the password is NULL or it has aged
    new_authtok_reqd = 12,
    /// User account has expired
    acct_expired = 13,
    /// Can not make/remove an entry for the specified session
    session_err = 14,
    /// Underlying authentication service can not retrieve user credentials unavailable
    cred_unavail = 15,
    /// User credentials expired
    cred_expired = 16,
    /// Failure setting user credentials
    cred_err = 17,
    /// No module specific data is present
    no_module_data = 18,
    /// Conversation error
    conv_err = 19,
    /// Authentication token manipulation error
    authtok_err = 20,
    /// Authentication information cannot be recovered
    authtok_recovery_err = 21,
    /// Authentication token lock busy
    authtok_lock_busy = 22,
    /// Authentication token aging disabled
    authtok_disable_aging = 23,
    /// Preliminary check by password service
    try_again = 24,
    /// Ignore underlying account module regardless of whether the control
    /// flag is required, optional, or sufficient
    ignore = 25,
    /// Critical error (?module fail now request)
    abort = 26,
    /// user's authentication token has expired
    authtok_expired = 27,
    /// module is not known
    module_unknown = 28,
    /// Bad item passed to pam_*_item()
    bad_item = 29,
    /// conversation function is event driven and data is not available yet
    conv_again = 30,
    /// please call this function again to complete authentication
    /// stack. Before calling again, verify that conversation is completed
    incomplete = 31,

    /// The pamh argument to this function is ignored by the implementation.
    extern fn pam_strerror(pamh: ?*Handle, errnum: Result) [*:0]const u8;
    pub fn description(result: Result) [*:0]const u8 {
        return pam_strerror(null, result);
    }
};

// Flags intended to be bitwise or'ed together
pub const flags = struct {

    /// Authentication service should not generate any messages
    pub const silent = 0x8000;

    // Note: these flags are used by pam_authenticate{,_secondary}()

    /// The authentication service should return .auth_err if
    /// user has a null authentication token
    pub const disallow_null_authtok = 0x0001;

    // Note: these flags are used for pam_setcred()

    /// Set user credentials for an authentication service
    pub const estblish_cred = 0x0002;

    /// Delete user credentials associated with an authentication service
    pub const delete_cred = 0x0004;

    /// Reinitialize user credentials
    pub const reinitialize_cred = 0x0008;

    /// Extend lifetime of user credentials
    pub const refresh_cred = 0x0010;
};
