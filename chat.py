import json
import urllib.request

# Local Port-forwarded URL
URL = "http://localhost:8001/v1/chat/completions"

print("🤖 Mistral-7B LLM Chatbot Active! (Type 'exit' to quit)\n")

messages = [
    {
        "role": "system",
        "content": "You are a friendly and smart AI assistant.",
    }
]

while True:
    user_input = input("You: ")
    if user_input.lower() in ["exit", "quit"]:
        print("Chat ended. Bye!")
        break

    messages.append({"role": "user", "content": user_input})

    payload = json.dumps(
        {
            "model": "mistralai/Mistral-7B-Instruct-v0.3",
            "messages": messages,
            "max_tokens": 500,
        }
    ).encode("utf-8")

    req = urllib.request.Request(
        URL, data=payload, headers={"Content-Type": "application/json"}
    )

    try:
        response = urllib.request.urlopen(req)
        result = json.loads(response.read().decode())
        bot_reply = result["choices"][0]["message"]["content"]
        print(f"\nMistral LLM: {bot_reply}\n")

        # Memory retain karne ke liye assistant ka reply add karo
        messages.append({"role": "assistant", "content": bot_reply})
    except Exception as e:
        print(f"Error: {e}")
