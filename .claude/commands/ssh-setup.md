Add your local SSH public key to tbaltzakis@omv's authorized_keys so you can SSH without a password.

Steps:
1. Ask the user to run this on their local machine and paste the output:
   cat ~/.ssh/id_ed25519.pub
   (or id_rsa.pub / id_ecdsa.pub if no ed25519 key exists)

2. If the user has no SSH key, ask them to generate one:
   ssh-keygen -t ed25519 -C "your-email"

3. Once you have the public key string, update the authorize-ssh-key dispatch file:
   - Set `triggered_at` to now
   - Set `inputs.public_key` to the full public key string

4. Commit and push to main. The authorize-ssh-key workflow will add the key via the
   existing GHA SSH connection (OMV_SSH_KEY secret).

5. After the workflow succeeds, test with:
   ssh tbaltzakis@<omv-tailscale-ip>
   (default Tailscale IP: 100.113.41.119)

Note: The public key is committed to the dispatch file in the repo. This is intentional
and safe — public keys are meant to be public. Never commit the private key.
