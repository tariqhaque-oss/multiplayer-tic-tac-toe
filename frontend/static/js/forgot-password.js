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
const forgotPasswordForm = document.getElementById("forgotPasswordForm");

forgotPasswordForm.addEventListener("submit", async (event) => {
    event.preventDefault();

    await postJSON("/api/auth/forgot-password", {
        email: document.getElementById("email").value,
    });

    messageDiv.innerText = "If that email is registered, a reset link was sent.";
});
