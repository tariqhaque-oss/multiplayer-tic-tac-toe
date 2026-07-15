async function postJSON(url, body) {
    const res = await fetch(url, {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
    });
    return res.json();
}

const messageDiv = document.getElementById("message");
const signupForm = document.getElementById("signupForm");

const errors = {
    taken: "That email is already registered.",
    nickname_taken: "That display name is already taken.",
    mismatch: "Passwords do not match.",
    weak: "Password must be 8-72 characters.",
    invalid_email: "Please enter a valid email address.",
    invalid_nickname: "Display name must be 3-24 characters: letters, numbers, underscore."
};

signupForm.addEventListener("submit", async (event) => {
    event.preventDefault();

    const data = await postJSON("/api/auth/signup", {
        email: document.getElementById("email").value,
        nickname: document.getElementById("nickname").value,
        password: document.getElementById("password").value,
        confirm_password: document.getElementById("confirm_password").value,
    });

    if (data.ok) {
        location.href = "/login.html?created=1";
        return;
    }

    messageDiv.innerText = errors[data.error] || "Something went wrong. Please try again.";
    messageDiv.classList.add("error");
});
