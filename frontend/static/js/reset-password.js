const params = new URLSearchParams(location.search);
const messageDiv = document.getElementById("message");
const errors = {
    mismatch: "Passwords do not match.",
    weak: "Password must be 8-72 characters.",
    reused: "You've already used that password before. Choose a different one."
};

const token = params.get("token") || "";
document.getElementById("token").value = token;

const error = params.get("error");
if (error && errors[error]) {
    messageDiv.innerText = errors[error];
    messageDiv.classList.add("error");
}

if (!token) {
    messageDiv.innerText = "Missing or invalid reset link.";
    messageDiv.classList.add("error");
}
