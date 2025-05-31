# Dropbox Sign Download Tool

This Ruby script downloads all signed documents from your [Dropbox Sign (formerly HelloSign)](https://www.hellosign.com/) account. It saves each document with a readable filename and keeps a status log of every download, so you can easily see which files succeeded or failed.

## Features

- **Downloads every signed document** from your Dropbox Sign account.
- **Names each file** using the document's title (or envelope name).
- **Handles rate limits** (HTTP 429) with automatic retries.
- **Keeps a status log** (JSON) of all downloads, including errors.
- **No external Ruby gems required** — just standard Ruby!

---

## Requirements

- Ruby 2.7 or newer (comes pre-installed on most Linux and macOS systems).
- A Dropbox Sign API key ([get one here](https://app.hellosign.com/home/myAccount#api)).

---

## Setup

1. **Download the script**

   Download the file `download_all_signed_docs.rb` to a folder on your computer.

2. **Make it executable (optional, for Linux/macOS):**

   ```sh
   chmod +x download_all_signed_docs.rb
   ```

3. **Set your Dropbox Sign API key as an environment variable:**

   On Linux/macOS:
   ```sh
   export HELLOSIGN_API_KEY=your_api_key_here
   ```

   On Windows (Command Prompt):
   ```cmd
   set HELLOSIGN_API_KEY=your_api_key_here
   ```

   On Windows (PowerShell):
   ```powershell
   $env:HELLOSIGN_API_KEY="your_api_key_here"
   ```

---

## Usage

Run the script from the command line:

```sh
ruby download_all_signed_docs.rb
```

- The script will create a new folder named like `signed_docs_<timestamp>` (with a timestamp).
- All downloaded PDFs will be saved in this folder.
- A file called `download_status_<timestamp>.json` will be created in the same folder, showing the status of every download.

---

## What if I get errors or need to stop the script?

- If you press `Ctrl+C` to stop the script, it will still save the status log of what was downloaded so far.
- If you see errors about your API key, double-check that you set the `HELLOSIGN_API_KEY` environment variable correctly.

---

## How do I see what was downloaded?

- Open the `signed_docs_<timestamp>` folder to see your PDFs.
- Open the `download_status_<timestamp>.json` file in a text editor to see which files succeeded or failed.

---

## Troubleshooting

- **Nothing downloads:** Make sure your API key is correct and your account has signed documents.
- **Permission denied:** Try running `chmod +x download_all_signed_docs.rb` or use `ruby download_all_signed_docs.rb` instead of `./download_all_signed_docs.rb`.

---

## License

MIT License. See [LICENSE](LICENSE) for details. 