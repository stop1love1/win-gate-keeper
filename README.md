# AdminGate — User guide

AdminGate helps you **set up a Windows PC or server** so other people can connect using **SFTP** (secure file transfer) or **SSH** (remote command-line login), with **separate accounts**, **separate folders**, and **activity logging**. You work in a **menu inside a dark window** (PowerShell): read the prompts on screen and type the number or letter it asks for, then press Enter.

---

## Before you start

- The machine should run **Windows 10**, **Windows 11**, or **Windows Server** (a version still supported by Microsoft).
- You must be signed in to Windows with an account that has **Administrator** rights on that machine.
- Copy the **entire program folder** (with all files inside) onto the machine that will act as the access server.

**Important:** The tool can change system settings (services, firewall, network-related configuration). Only run it on machines you **trust** and that you are **allowed to manage**.

---

## How to open AdminGate (easiest way)

1. Open the folder that contains AdminGate.
2. **Double-click** **`run.cmd`** or **`run.bat`**.
3. If Windows asks **“Do you want to allow this app to make changes to your device?”** — choose **Yes** (this grants administrator permission).
4. A new window opens — that is where you use the AdminGate menu.

If something **goes wrong** (missing file, failure to start…), the window often **stays open** so you can read red or yellow messages. Take a screenshot or copy the text to share with whoever supports you.

---

## What to do the first time

**Fast path (recommended for beginners):**

1. When the main menu appears, choose **`0`** — **Quick Setup (All Steps)**.
2. When it asks to continue, type **`Y`** and press Enter if you agree.
3. Wait until the steps finish. If you see error lines, do not ignore them — read them carefully or ask someone with more experience to help.

**Quick Setup** will, in order: create the working folders, turn on the **OpenSSH** service (so others can connect in), set up **SFTP** (file transfer only, limited to the allowed user area), and turn on **audit-style logging** and **PowerShell logging** using the tool’s default options.

When that is done, open **`2` — User Management** to **create accounts** for each SFTP or SSH user.

---

## Main menu choices (type the key, then Enter)

| Key | In plain words |
|-----|----------------|
| **0** | Run **full quick setup** once (typical for a new machine). |
| **1** | **OpenSSH:** install or check the service so people can connect remotely; you can set the default “command window” type for SSH logins. |
| **2** | **Users:** create, list, disable/enable, reset password, remove users. |
| **3** | **Folders:** create the standard folder layout, check everything exists, **fix permissions** if user folders are wrong. |
| **4** | **SFTP:** configure “SFTP-only” users so they stay inside the allowed area; view settings; try a test connection. |
| **5** | **Logs & auditing:** turn logging on or off, view status, view recent logs (sign-ins, file access, and similar). |
| **S** | **Overview:** quick check whether the machine looks ready (service, folders, SFTP group, and so on). |
| **C** | **Configuration:** change the main folder path, SFTP group name, or open the settings file in Notepad (get help if you edit the file by hand). |
| **Q** | **Quit** the program. |

Some lines may show **[OK]** or **[NOT CONFIGURED]** — a quick hint whether that part looks fine or still needs setup.

---

## When you create a new user, which type?

- **SFTP only (Standard):** That person can **only transfer files** (like an FTP app) and **cannot** use a full remote command shell. Good for partners who only need to send or receive files.
- **Shell (SSH + SFTP):** That person can use a **remote command line** (depending on how the server shell is set). For admins or people who need to work on the server directly.

---

## Settings file (when you need to change folders or port)

Inside the program folder you will find **`config\settings.json`**. It defines:

- The **main working folder** for AdminGate.
- The **folder that holds each user’s area** (where “SFTP-only” users are kept).
- Where **logs** are stored.
- The **network port** opened in the firewall when OpenSSH is installed (often **22**).

**Recommendation:** Set these paths **before** you create many users and go into real use. Changing folders later can misalign settings — ask someone experienced if you are unsure.

From the menu, **C** lets you change common items or open this file in Notepad.

---

## Practical notes

- **Windows in a language other than English:** Some “file auditing” steps may show warnings because system names differ by language. If you see yellow warnings, read the text under menu **5** or ask for help.
- **SSH config backups:** Before changing the SSH server configuration, the tool usually keeps a **dated backup file** — keep it until you are sure everything works.
- **User passwords:** Use strong passwords and share them only with people who should have access.

---

## What is AdminGate? (one line)

**A Windows menu tool that turns on SFTP/SSH access safely, creates users and private folders, and enables logging — for server administrators who do not want to type long manual commands for every step.**
