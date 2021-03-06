;;; smime.el --- S/MIME support library

;; Copyright (C) 2000, 2001, 2002, 2003, 2004,
;;   2005, 2006, 2007 Free Software Foundation, Inc.

;; Author: Simon Josefsson <simon@josefsson.org>
;; Keywords: SMIME X.509 PEM OpenSSL

;; This file is part of GNU Emacs.

;; GNU Emacs is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published
;; by the Free Software Foundation; either version 2, or (at your
;; option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; This library perform S/MIME operations from within Emacs.
;;
;; Functions for fetching certificates from public repositories are
;; provided, currently only from DNS.  LDAP support (via EUDC) is planned.
;;
;; It uses OpenSSL (tested with version 0.9.5a and 0.9.6) for signing,
;; encryption and decryption.
;;
;; Some general knowledge of S/MIME, X.509, PKCS#12, PEM etc is
;; probably required to use this library in any useful way.
;; Especially, don't expect this library to buy security for you.  If
;; you don't understand what you are doing, you're as likely to lose
;; security than gain any by using this library.
;;
;; This library is not intended to provide a "raw" API for S/MIME,
;; PKCSx or similar, it's intended to perform common operations
;; done on messages encoded in these formats.  The terminology chosen
;; reflect this.
;;
;; The home of this file is in Gnus CVS, but also available from
;; http://josefsson.org/smime.html.

;;; Quick introduction:

;; Get your S/MIME certificate from VeriSign or someplace.  I used
;; Netscape to generate the key and certificate request and stuff, and
;; Netscape can export the key into PKCS#12 format.
;;
;; Enter OpenSSL.  To be able to use this library, it need to have the
;; SMIME key readable in PEM format.  OpenSSL is used to convert the
;; key:
;;
;; $ openssl pkcs12 -in mykey.p12 -clcerts -nodes > mykey.pem
;; ...
;;
;; Now, use M-x customize-variable smime-keys and add mykey.pem as
;; a key.
;;
;; Now you should be able to sign messages!  Create a buffer and write
;; something and run M-x smime-sign-buffer RET RET and you should see
;; your message MIME armoured and a signature.  Encryption, M-x
;; smime-encrypt-buffer, should also work.
;;
;; To be able to verify messages you need to build up trust with
;; someone.  Perhaps you trust the CA that issued your certificate, at
;; least I did, so I export it's certificates from my PKCS#12
;; certificate with:
;;
;; $ openssl pkcs12 -in mykey.p12 -cacerts -nodes > cacert.pem
;; ...
;;
;; Now, use M-x customize-variable smime-CAs and add cacert.pem as a
;; CA certificate.
;;
;; You should now be able to sign messages, and even verify messages
;; sent by others that use the same CA as you.

;; Bugs:
;;
;; Don't complain that this package doesn't do encrypted PEM files,
;; submit a patch instead.  I store my keys in a safe place, so I
;; didn't need the encryption.  Also, programming was made easier by
;; that decision.  One might think that this even influenced were I
;; store my keys, and one would probably be right. :-)
;;
;; Update: Mathias Herberts sent the patch.  However, it uses
;; environment variables to pass the password to OpenSSL, which is
;; slightly insecure. Hence a new todo: use a better -passin method.
;;
;; Cache password for e.g. 1h
;;
;; Suggestions and comments are appreciated, mail me at simon@josefsson.org.

;; begin rant
;;
;; I would include pointers to introductory text on concepts used in
;; this library here, but the material I've read are so horrible I
;; don't want to recomend them.
;;
;; Why can't someone write a simple introduction to all this stuff?
;; Until then, much of this resemble security by obscurity.
;;
;; Also, I'm not going to mention anything about the wonders of
;; cryptopolitics.  Oops, I just did.
;;
;; end rant

;;; Revision history:

;; 2000-06-05  initial version, committed to Gnus CVS contrib/
;; 2000-10-28  retrieve certificates via DNS CERT RRs
;; 2001-10-14  posted to gnu.emacs.sources

;;; Code:

(require 'dig)
(eval-when-compile (require 'cl))

(defgroup smime nil
  "S/MIME configuration."
  :group 'mime)

(defcustom smime-keys nil
  "*Map mail addresses to a file containing Certificate (and private key).
The file is assumed to be in PEM format. You can also associate additional
certificates to be sent with every message to each address."
  :type '(repeat (list (string :tag "Mail address")
		       (file :tag "File name")
		       (repeat :tag "Additional certificate files"
			       (file :tag "File name"))))
  :group 'smime)

(defcustom smime-CA-directory nil
  "*Directory containing certificates for CAs you trust.
Directory should contain files (in PEM format) named to the X.509
hash of the certificate.  This can be done using OpenSSL such as:

$ ln -s ca.pem `openssl x509 -noout -hash -in ca.pem`.0

where `ca.pem' is the file containing a PEM encoded X.509 CA
certificate."
  :type '(choice (const :tag "none" nil)
		 directory)
  :group 'smime)

(defcustom smime-CA-file nil
  "*Files containing certificates for CAs you trust.
File should contain certificates in PEM format."
  :version "22.1"
  :type '(choice (const :tag "none" nil)
		 file)
  :group 'smime)

(defcustom smime-certificate-directory "~/Mail/certs/"
  "*Directory containing other people's certificates.
It should contain files named to the X.509 hash of the certificate,
and the files themself should be in PEM format."
;The S/MIME library provide simple functionality for fetching
;certificates into this directory, so there is no need to populate it
;manually.
  :type 'directory
  :group 'smime)

(defcustom smime-openssl-program
  (and (condition-case ()
	   (eq 0 (call-process "openssl" nil nil nil "version"))
	 (error nil))
       "openssl")
  "*Name of OpenSSL binary."
  :type 'string
  :group 'smime)

;; OpenSSL option to select the encryption cipher

(defcustom smime-encrypt-cipher "-des3"
  "*Cipher algorithm used for encryption."
  :version "22.1"
  :type '(choice (const :tag "Triple DES" "-des3")
		 (const :tag "DES"  "-des")
		 (const :tag "RC2 40 bits" "-rc2-40")
		 (const :tag "RC2 64 bits" "-rc2-64")
		 (const :tag "RC2 128 bits" "-rc2-128"))
  :group 'smime)

(defcustom smime-crl-check nil
  "*Check revocation status of signers certificate using CRLs.
Enabling this will have OpenSSL check the signers certificate
against a certificate revocation list (CRL).

For this to work the CRL must be up-to-date and since they are
normally updated quite often (ie. several times a day) you
probably need some tool to keep them up-to-date. Unfortunately
Gnus cannot do this for you.

The CRL should either be appended (in PEM format) to your
`smime-CA-file' or be located in a file (also in PEM format) in
your `smime-certificate-directory' named to the X.509 hash of the
certificate with .r0 as file name extension.

At least OpenSSL version 0.9.7 is required for this to work."
  :type '(choice (const :tag "No check" nil)
		 (const :tag "Check certificate" "-crl_check")
		 (const :tag "Check certificate chain" "-crl_check_all"))
  :group 'smime)

(defcustom smime-dns-server nil
  "*DNS server to query certificates from.
If nil, use system defaults."
  :version "22.1"
  :type '(choice (const :tag "System defaults")
		 string)
  :group 'smime)

(defvar smime-details-buffer "*OpenSSL output*")

;; Use mm-util?
(eval-and-compile
  (defalias 'smime-make-temp-file
    (if (fboundp 'make-temp-file)
	'make-temp-file
      (lambda (prefix &optional dir-flag) ;; Simple implementation
	(expand-file-name
	 (make-temp-name prefix)
	 (if (fboundp 'temp-directory)
	     (temp-directory)
	   temporary-file-directory))))))

;; Password dialog function

(defun smime-ask-passphrase ()
  "Asks the passphrase to unlock the secret key."
  (let ((passphrase
	 (read-passwd
	  "Passphrase for secret key (RET for no passphrase): ")))
    (if (string= passphrase "")
	nil
      passphrase)))

;; OpenSSL wrappers.

(defun smime-call-openssl-region (b e buf &rest args)
  (case (apply 'call-process-region b e smime-openssl-program nil buf nil args)
    (0 t)
    (1 (message "OpenSSL: An error occurred parsing the command options.") nil)
    (2 (message "OpenSSL: One of the input files could not be read.") nil)
    (3 (message "OpenSSL: An error occurred creating the PKCS#7 file or when reading the MIME message.") nil)
    (4 (message "OpenSSL: An error occurred decrypting or verifying the message.") nil)
    (t (error "Unknown OpenSSL exitcode") nil)))

(defun smime-make-certfiles (certfiles)
  (if certfiles
      (append (list "-certfile" (expand-file-name (car certfiles)))
	      (smime-make-certfiles (cdr certfiles)))))

;; Sign+encrypt region

(defun smime-sign-region (b e keyfile)
  "Sign region with certified key in KEYFILE.
If signing fails, the buffer is not modified.  Region is assumed to
have proper MIME tags.  KEYFILE is expected to contain a PEM encoded
private key and certificate as its car, and a list of additional
certificates to include in its caar.  If no additional certificates is
included, KEYFILE may be the file containing the PEM encoded private
key and certificate itself."
  (smime-new-details-buffer)
  (let ((keyfile (or (car-safe keyfile) keyfile))
	(certfiles (and (cdr-safe keyfile) (cadr keyfile)))
	(buffer (generate-new-buffer (generate-new-buffer-name " *smime*")))
	(passphrase (smime-ask-passphrase))
	(tmpfile (smime-make-temp-file "smime")))
    (if passphrase
	(setenv "GNUS_SMIME_PASSPHRASE" passphrase))
    (prog1
	(when (prog1
		  (apply 'smime-call-openssl-region b e (list buffer tmpfile)
			 "smime" "-sign" "-signer" (expand-file-name keyfile)
			 (append
			  (smime-make-certfiles certfiles)
			  (if passphrase
			      (list "-passin" "env:GNUS_SMIME_PASSPHRASE"))))
		(if passphrase
		    (setenv "GNUS_SMIME_PASSPHRASE" "" t))
		(with-current-buffer smime-details-buffer
		  (insert-file-contents tmpfile)
		  (delete-file tmpfile)))
	  (delete-region b e)
	  (insert-buffer-substring buffer)
	  (goto-char b)
	  (when (looking-at "^MIME-Version: 1.0$")
	    (delete-region (point) (progn (forward-line 1) (point))))
	  t)
      (with-current-buffer smime-details-buffer
	(goto-char (point-max))
	(insert-buffer-substring buffer))
      (kill-buffer buffer))))

(defun smime-encrypt-region (b e certfiles)
  "Encrypt region for recipients specified in CERTFILES.
If encryption fails, the buffer is not modified.  Region is assumed to
have proper MIME tags.  CERTFILES is a list of filenames, each file
is expected to contain of a PEM encoded certificate."
  (smime-new-details-buffer)
  (let ((buffer (generate-new-buffer (generate-new-buffer-name " *smime*")))
	(tmpfile (smime-make-temp-file "smime")))
    (prog1
	(when (prog1
		  (apply 'smime-call-openssl-region b e (list buffer tmpfile)
			 "smime" "-encrypt" smime-encrypt-cipher
			 (mapcar 'expand-file-name certfiles))
		(with-current-buffer smime-details-buffer
		  (insert-file-contents tmpfile)
		  (delete-file tmpfile)))
	  (delete-region b e)
	  (insert-buffer-substring buffer)
	  (goto-char b)
	  (when (looking-at "^MIME-Version: 1.0$")
	    (delete-region (point) (progn (forward-line 1) (point))))
	  t)
      (with-current-buffer smime-details-buffer
	(goto-char (point-max))
	(insert-buffer-substring buffer))
      (kill-buffer buffer))))

;; Sign+encrypt buffer

(defun smime-sign-buffer (&optional keyfile buffer)
  "S/MIME sign BUFFER with key in KEYFILE.
KEYFILE should contain a PEM encoded key and certificate."
  (interactive)
  (with-current-buffer (or buffer (current-buffer))
    (unless (smime-sign-region
	     (point-min) (point-max)
	     (if keyfile
		 keyfile
	       (smime-get-key-with-certs-by-email
		(completing-read
		 (concat "Sign using key"
			 (if smime-keys
			     (concat " (default " (caar smime-keys) "): ")
			   ": "))
		 smime-keys nil nil (car-safe (car-safe smime-keys))))))
      (error "Signing failed"))))

(defun smime-encrypt-buffer (&optional certfiles buffer)
  "S/MIME encrypt BUFFER for recipients specified in CERTFILES.
CERTFILES is a list of filenames, each file is expected to consist of
a PEM encoded key and certificate.  Uses current buffer if BUFFER is
nil."
  (interactive)
  (with-current-buffer (or buffer (current-buffer))
    (unless (smime-encrypt-region
	     (point-min) (point-max)
	     (or certfiles
		 (list (read-file-name "Recipient's S/MIME certificate: "
				       smime-certificate-directory nil))))
      (error "Encryption failed"))))

;; Verify+decrypt region

(defun smime-verify-region (b e)
  "Verify S/MIME message in region between B and E.
Returns non-nil on success.
Any details (stdout and stderr) are left in the buffer specified by
`smime-details-buffer'."
  (smime-new-details-buffer)
  (let ((CAs (append (if smime-CA-file
			 (list "-CAfile"
			       (expand-file-name smime-CA-file)))
		     (if smime-CA-directory
			 (list "-CApath"
			       (expand-file-name smime-CA-directory))))))
    (unless CAs
      (error "No CA configured"))
    (if smime-crl-check
	(add-to-list 'CAs smime-crl-check))
    (if (apply 'smime-call-openssl-region b e (list smime-details-buffer t)
	       "smime" "-verify" "-out" "/dev/null" CAs)
	t
      (insert-buffer-substring smime-details-buffer)
      nil)))

(defun smime-noverify-region (b e)
  "Verify integrity of S/MIME message in region between B and E.
Returns non-nil on success.
Any details (stdout and stderr) are left in the buffer specified by
`smime-details-buffer'."
  (smime-new-details-buffer)
  (if (apply 'smime-call-openssl-region b e (list smime-details-buffer t)
	     "smime" "-verify" "-noverify" "-out" '("/dev/null"))
      t
    (insert-buffer-substring smime-details-buffer)
    nil))

(eval-when-compile
  (defvar from))

(defun smime-decrypt-region (b e keyfile)
  "Decrypt S/MIME message in region between B and E with key in KEYFILE.
On success, replaces region with decrypted data and return non-nil.
Any details (stderr on success, stdout and stderr on error) are left
in the buffer specified by `smime-details-buffer'."
  (smime-new-details-buffer)
  (let ((buffer (generate-new-buffer (generate-new-buffer-name " *smime*")))
	CAs (passphrase (smime-ask-passphrase))
	(tmpfile (smime-make-temp-file "smime")))
    (if passphrase
	(setenv "GNUS_SMIME_PASSPHRASE" passphrase))
    (if (prog1
	    (apply 'smime-call-openssl-region b e
		   (list buffer tmpfile)
		   "smime" "-decrypt" "-recip" (expand-file-name keyfile)
		   (if passphrase
		       (list "-passin" "env:GNUS_SMIME_PASSPHRASE")))
	  (if passphrase
	      (setenv "GNUS_SMIME_PASSPHRASE" "" t))
	  (with-current-buffer smime-details-buffer
	    (insert-file-contents tmpfile)
	    (delete-file tmpfile)))
	(progn
	  (delete-region b e)
	  (when (boundp 'from)
	    ;; `from' is dynamically bound in mm-dissect.
	    (insert "From: " from "\n"))
	  (insert-buffer-substring buffer)
	  (kill-buffer buffer)
	  t)
      (with-current-buffer smime-details-buffer
	(insert-buffer-substring buffer))
      (kill-buffer buffer)
      (delete-region b e)
      (insert-buffer-substring smime-details-buffer)
      nil)))

;; Verify+Decrypt buffer

(defun smime-verify-buffer (&optional buffer)
  "Verify integrity of S/MIME message in BUFFER.
Uses current buffer if BUFFER is nil. Returns non-nil on success.
Any details (stdout and stderr) are left in the buffer specified by
`smime-details-buffer'."
  (interactive)
  (with-current-buffer (or buffer (current-buffer))
    (smime-verify-region (point-min) (point-max))))

(defun smime-noverify-buffer (&optional buffer)
  "Verify integrity of S/MIME message in BUFFER.
Does NOT verify validity of certificate (only message integrity).
Uses current buffer if BUFFER is nil. Returns non-nil on success.
Any details (stdout and stderr) are left in the buffer specified by
`smime-details-buffer'."
  (interactive)
  (with-current-buffer (or buffer (current-buffer))
    (smime-noverify-region (point-min) (point-max))))

(defun smime-decrypt-buffer (&optional buffer keyfile)
  "Decrypt S/MIME message in BUFFER using KEYFILE.
Uses current buffer if BUFFER is nil, and query user of KEYFILE if it's nil.
On success, replaces data in buffer and return non-nil.
Any details (stderr on success, stdout and stderr on error) are left
in the buffer specified by `smime-details-buffer'."
  (interactive)
  (with-current-buffer (or buffer (current-buffer))
    (smime-decrypt-region
     (point-min) (point-max)
     (expand-file-name
      (or keyfile
	  (smime-get-key-by-email
	   (completing-read
	    (concat "Decipher using key"
		    (if smime-keys (concat " (default " (caar smime-keys) "): ")
		      ": "))
	    smime-keys nil nil (car-safe (car-safe smime-keys)))))))))

;; Various operations

(defun smime-new-details-buffer ()
  (with-current-buffer (get-buffer-create smime-details-buffer)
    (erase-buffer)))

(defun smime-pkcs7-region (b e)
  "Convert S/MIME message between points B and E into a PKCS7 message."
  (smime-new-details-buffer)
  (when (smime-call-openssl-region b e smime-details-buffer "smime" "-pk7out")
    (delete-region b e)
    (insert-buffer-substring smime-details-buffer)
    t))

(defun smime-pkcs7-certificates-region (b e)
  "Extract any certificates enclosed in PKCS7 message between points B and E."
  (smime-new-details-buffer)
  (when (smime-call-openssl-region
	 b e smime-details-buffer "pkcs7" "-print_certs" "-text")
    (delete-region b e)
    (insert-buffer-substring smime-details-buffer)
    t))

(defun smime-pkcs7-email-region (b e)
  "Get email addresses contained in certificate between points B and E.
A string or a list of strings is returned."
  (smime-new-details-buffer)
  (when (smime-call-openssl-region
	 b e smime-details-buffer "x509" "-email" "-noout")
    (delete-region b e)
    (insert-buffer-substring smime-details-buffer)
    t))

;; Utility functions

(defun smime-get-certfiles (keyfile keys)
  (if keys
      (let ((curkey (car keys))
	    (otherkeys (cdr keys)))
	(if (string= keyfile (cadr curkey))
	    (caddr curkey)
	  (smime-get-certfiles keyfile otherkeys)))))

;; Use mm-util?
(eval-and-compile
  (defalias 'smime-point-at-eol
    (if (fboundp 'point-at-eol)
	'point-at-eol
      'line-end-position)))

(defun smime-buffer-as-string-region (b e)
  "Return each line in region between B and E as a list of strings."
  (save-excursion
    (goto-char b)
    (let (res)
      (while (< (point) e)
	(let ((str (buffer-substring (point) (smime-point-at-eol))))
	  (unless (string= "" str)
	    (push str res)))
	(forward-line))
      res)))

;; Find certificates

(defun smime-mail-to-domain (mailaddr)
  (if (string-match "@" mailaddr)
      (replace-match "." 'fixedcase 'literal mailaddr)
    mailaddr))

(defun smime-cert-by-dns (mail)
  (let* ((dig-dns-server smime-dns-server)
	 (digbuf (dig-invoke (smime-mail-to-domain mail) "cert" nil nil "+vc"))
	 (retbuf (generate-new-buffer (format "*certificate for %s*" mail)))
	 (certrr (with-current-buffer digbuf
		   (dig-extract-rr (smime-mail-to-domain mail) "cert")))
	 (cert (and certrr (dig-rr-get-pkix-cert certrr))))
      (if cert
	  (with-current-buffer retbuf
	    (insert "-----BEGIN CERTIFICATE-----\n")
	    (let ((i 0) (len (length cert)))
	      (while (> (- len 64) i)
		(insert (substring cert i (+ i 64)) "\n")
		(setq i (+ i 64)))
	      (insert (substring cert i len) "\n"))
	    (insert "-----END CERTIFICATE-----\n"))
	(kill-buffer retbuf)
	(setq retbuf nil))
      (kill-buffer digbuf)
      retbuf))

;; User interface.

(defvar smime-buffer "*SMIME*")

(defvar smime-mode-map nil)
(put 'smime-mode 'mode-class 'special)

(unless smime-mode-map
  (setq smime-mode-map (make-sparse-keymap))
  (suppress-keymap smime-mode-map)

  (define-key smime-mode-map "q" 'smime-exit)
  (define-key smime-mode-map "f" 'smime-certificate-info))

(defun smime-mode ()
  "Major mode for browsing, viewing and fetching certificates.

All normal editing commands are switched off.
\\<smime-mode-map>

The following commands are available:

\\{smime-mode-map}"
  (interactive)
  (kill-all-local-variables)
  (setq major-mode 'smime-mode)
  (setq mode-name "SMIME")
  (setq mode-line-process nil)
  (use-local-map smime-mode-map)
  (buffer-disable-undo)
  (setq truncate-lines t)
  (setq buffer-read-only t)
  (gnus-run-mode-hooks 'smime-mode-hook))

(defun smime-certificate-info (certfile)
  (interactive "fCertificate file: ")
  (let ((buffer (get-buffer-create (format "*certificate %s*" certfile))))
    (switch-to-buffer buffer)
    (erase-buffer)
    (call-process smime-openssl-program nil buffer 'display
		  "x509" "-in" (expand-file-name certfile) "-text")
    (fundamental-mode)
    (set-buffer-modified-p nil)
    (toggle-read-only t)
    (goto-char (point-min))))

(defun smime-draw-buffer ()
  (with-current-buffer smime-buffer
    (let (buffer-read-only)
      (erase-buffer)
      (insert "\nYour keys:\n")
      (dolist (key smime-keys)
	(insert
	 (format "\t\t%s: %s\n" (car key) (cadr key))))
      (insert "\nTrusted Certificate Authoritys:\n")
      (insert "\nKnown Certificates:\n"))))

(defun smime ()
  "Go to the SMIME buffer."
  (interactive)
  (unless (get-buffer smime-buffer)
    (save-excursion
      (set-buffer (get-buffer-create smime-buffer))
      (smime-mode)))
  (smime-draw-buffer)
  (switch-to-buffer smime-buffer))

(defun smime-exit ()
  "Quit the S/MIME buffer."
  (interactive)
  (kill-buffer (current-buffer)))

;; Other functions

(defun smime-get-key-by-email (email)
  (cadr (assoc email smime-keys)))

(defun smime-get-key-with-certs-by-email (email)
  (cdr (assoc email smime-keys)))

(provide 'smime)

;;; arch-tag: e3f9b938-5085-4510-8a11-6625269c9a9e
;;; smime.el ends here
