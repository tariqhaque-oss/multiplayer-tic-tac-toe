const params = new URLSearchParams(location.search);
const messageDiv = document.getElementById("message");
const errors = {
    taken: "That email is already registered.",
    nickname_taken: "That display name is already taken.",
    mismatch: "Passwords do not match.",
    weak: "Password must be 8-72 characters.",
    invalid_email: "Please enter a valid email address.",
    invalid_nickname: "Display name must be 3-24 characters: letters, numbers, underscore."
};

const error = params.get("error");
if (error && errors[error]) {
    messageDiv.innerText = errors[error];
    messageDiv.classList.add("error");
}
