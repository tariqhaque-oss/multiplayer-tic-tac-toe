const params = new URLSearchParams(location.search);
const messageDiv = document.getElementById("message");
const resendForm = document.getElementById("resendForm");
const emailInput = document.getElementById("email");

const error = params.get("error");

if (error === "invalid") {
    messageDiv.innerText = "Invalid email or password.";
    messageDiv.classList.add("error");
} else if (error === "unverified") {
    messageDiv.innerText = "Please verify your email before logging in.";
    messageDiv.classList.add("error");
    resendForm.style.display = "block";
} else if (error === "invalid_token") {
    messageDiv.innerText = "That verification link is invalid or has expired.";
    messageDiv.classList.add("error");
} else if (error === "invalid_reset_link") {
    messageDiv.innerText = "That password reset link is invalid or has expired.";
    messageDiv.classList.add("error");
} else if (params.get("created") === "1") {
    messageDiv.innerText = "Account created. Check your email for a verification link.";
} else if (params.get("verified") === "1") {
    messageDiv.innerText = "Email verified. You can log in now.";
} else if (params.get("resent") === "1") {
    messageDiv.innerText = "If that account needs verifying, a new email was sent.";
} else if (params.get("reset_requested") === "1") {
    messageDiv.innerText = "If that email is registered, a reset link was sent.";
} else if (params.get("reset_done") === "1") {
    messageDiv.innerText = "Password updated. You can log in now.";
} else if (params.get("logged_out") === "1") {
    messageDiv.innerText = "You have been logged out.";
}

resendForm.addEventListener("submit", () => {
    document.getElementById("resendEmail").value = emailInput.value;
});