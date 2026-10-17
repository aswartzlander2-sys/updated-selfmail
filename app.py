from flask import Flask
app = Flask(__name__)

@app.route('/')
def home():
    return "Mailhook Active"

@app.route('/webhook', methods=['POST'])
def webhook():
    return "Received", 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=80)
