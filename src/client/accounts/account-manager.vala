/* Copyright 2017 Software Freedom Conservancy Inc.
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution.
 */

public class AccountManager : GLib.Object {


    private Geary.Engine engine;


    public AccountManager(Geary.Engine engine) {
        this.engine = engine;
    }


    public async void add_existing_accounts_async(Cancellable? cancellable = null) throws Error {
        yield Geary.Files.make_directory_with_parents(
            this.engine.user_data_dir, cancellable
        );

        FileEnumerator enumerator
            = yield this.engine.user_config_dir.enumerate_children_async("standard::*",
                FileQueryInfoFlags.NONE, Priority.DEFAULT, cancellable);

        Gee.List<Geary.AccountInformation> account_list = new Gee.ArrayList<Geary.AccountInformation>();

        Geary.CredentialsMediator mediator = new SecretMediator();
        for (;;) {
            List<FileInfo> info_list;
            try {
                info_list = yield enumerator.next_files_async(1, Priority.DEFAULT, cancellable);
            } catch (Error e) {
                debug("Error enumerating existing accounts: %s", e.message);
                break;
            }

            if (info_list.length() == 0)
                break;

            FileInfo info = info_list.nth_data(0);
            if (info.get_file_type() == FileType.DIRECTORY) {
//                try {
                    string id = info.get_name();
                    account_list.add(
                        load_from_file(id)
                    );
/*                } catch (Error err) {
                    warning("Ignoring empty/bad config in %s: %s",
                            info.get_name(), err.message);
                } */
            }
        }

        foreach(Geary.AccountInformation info in account_list)
            Geary.Engine.instance.add_account(info);
     }

    /**
     * Loads an account info from a config directory.
     *
     * Throws an error if the config file was not found, could not be
     * parsed, or doesn't have all required fields.
     */
    public Geary.AccountInformation? load_from_file(string id)
        throws Error {

        File file = this.engine.user_config_dir.get_child(id).get_child(Geary.Config.SETTINGS_FILENAME);

        KeyFile key_file = new KeyFile();
        key_file.load_from_file(file.get_path() ?? "", KeyFileFlags.NONE);

        Geary.CredentialsMediator mediator;
        Geary.ServiceInformation imap_information;
        Geary.ServiceInformation smtp_information;
        Geary.CredentialsProvider provider;
        Geary.CredentialsMethod method;

        provider = Geary.CredentialsProvider.from_string(Geary.Config.get_string_value(key_file, Geary.Config.GROUP, Geary.Config.CREDENTIALS_PROVIDER_KEY, Geary.CredentialsProvider.LIBSECRET.to_string()));
        method = Geary.CredentialsMethod.from_string(Geary.Config.get_string_value(key_file, Geary.Config.GROUP, Geary.Config.CREDENTIALS_METHOD_KEY, Geary.CredentialsMethod.PASSWORD.to_string()));
        switch (provider) {
            case Geary.CredentialsProvider.LIBSECRET:
                mediator = new SecretMediator();
                imap_information = new Geary.LocalServiceInformation(Geary.Service.IMAP, this.engine.user_config_dir.get_child(id), mediator);
                smtp_information = new Geary.LocalServiceInformation(Geary.Service.SMTP, this.engine.user_config_dir.get_child(id), mediator);
                break;
            default:
                mediator = null;
                imap_information = null;
                smtp_information = null;
                break;
        }

        Geary.AccountInformation info = new Geary.AccountInformation(id,
                            this.engine.user_config_dir.get_child(id),
                            this.engine.user_data_dir.get_child(id),
                            imap_information,
                            smtp_information);



        // This is the only required value at the moment?
        string primary_email = key_file.get_value(Geary.Config.GROUP, Geary.Config.PRIMARY_EMAIL_KEY);
        string real_name = Geary.Config.get_string_value(key_file, Geary.Config.GROUP, Geary.Config.REAL_NAME_KEY);

        info.primary_mailbox = new Geary.RFC822.MailboxAddress(real_name, primary_email);
        info.nickname = Geary.Config.get_string_value(key_file, Geary.Config.GROUP, Geary.Config.NICKNAME_KEY);

        // Store alternate emails in a list of case-insensitive strings
        Gee.List<string> alt_email_list = Geary.Config.get_string_list_value(key_file, Geary.Config.GROUP, Geary.Config.ALTERNATE_EMAILS_KEY);
        if (alt_email_list.size != 0) {
            foreach (string alt_email in alt_email_list) {
                Geary.RFC822.MailboxAddresses mailboxes = new Geary.RFC822.MailboxAddresses.from_rfc822_string(alt_email);
                foreach (Geary.RFC822.MailboxAddress mailbox in mailboxes.get_all())
                info.add_alternate_mailbox(mailbox);
            }
        }

        info.imap.load_credentials(key_file, primary_email);
        info.smtp.load_credentials(key_file, primary_email);

        info.service_provider = Geary.ServiceProvider.from_string(
            Geary.Config.get_string_value(
                key_file, Geary.Config.GROUP, Geary.Config.SERVICE_PROVIDER_KEY, Geary.ServiceProvider.GMAIL.to_string()));
        info.prefetch_period_days = Geary.Config.get_int_value(
            key_file, Geary.Config.GROUP, Geary.Config.PREFETCH_PERIOD_DAYS_KEY, info.prefetch_period_days);
        info.save_sent_mail = Geary.Config.get_bool_value(
            key_file, Geary.Config.GROUP, Geary.Config.SAVE_SENT_MAIL_KEY, info.save_sent_mail);
        info.ordinal = Geary.Config.get_int_value(
            key_file, Geary.Config.GROUP, Geary.Config.ORDINAL_KEY, info.ordinal);
        info.use_email_signature = Geary.Config.get_bool_value(
            key_file, Geary.Config.GROUP, Geary.Config.USE_EMAIL_SIGNATURE_KEY, info.use_email_signature);
        info.email_signature = Geary.Config.get_escaped_string(
            key_file, Geary.Config.GROUP, Geary.Config.EMAIL_SIGNATURE_KEY, info.email_signature);

        if (info.ordinal >= Geary.AccountInformation.default_ordinal)
            Geary.AccountInformation.default_ordinal = info.ordinal + 1;

        if (info.service_provider == Geary.ServiceProvider.OTHER) {
            info.imap.load_settings(key_file);
            info.smtp.load_settings(key_file);

            if (info.smtp.smtp_use_imap_credentials) {
                info.smtp.credentials.user = info.imap.credentials.user;
                info.smtp.credentials.pass = info.imap.credentials.pass;
            }
        }

        info.drafts_folder_path = Geary.AccountInformation.build_folder_path(
            Geary.Config.get_string_list_value(key_file, Geary.Config.GROUP, Geary.Config.DRAFTS_FOLDER_KEY));
        info.sent_mail_folder_path = Geary.AccountInformation.build_folder_path(
            Geary.Config.get_string_list_value(key_file, Geary.Config.GROUP, Geary.Config.SENT_MAIL_FOLDER_KEY));
        info.spam_folder_path = Geary.AccountInformation.build_folder_path(
            Geary.Config.get_string_list_value(key_file, Geary.Config.GROUP, Geary.Config.SPAM_FOLDER_KEY));
        info.trash_folder_path = Geary.AccountInformation.build_folder_path(
            Geary.Config.get_string_list_value(key_file, Geary.Config.GROUP, Geary.Config.TRASH_FOLDER_KEY));
        info.archive_folder_path = Geary.AccountInformation.build_folder_path(
            Geary.Config.get_string_list_value(key_file, Geary.Config.GROUP, Geary.Config.ARCHIVE_FOLDER_KEY));

        info.save_drafts = Geary.Config.get_bool_value(key_file, Geary.Config.GROUP, Geary.Config.SAVE_DRAFTS_KEY, true);

        return info;
    }

    public async void store_to_file(Geary.AccountInformation info,
                                    Cancellable? cancellable = null) {
        File? file = info.config_dir.get_child(Geary.Config.SETTINGS_FILENAME);

        if (file == null) {
            warning("Cannot save account, no file set.\n");
            return;
        }

        if (!info.config_dir.query_exists(cancellable)) {
            try {
                info.config_dir.make_directory_with_parents();
            } catch (Error err) {
                error("Error creating configuration directory for account '%s': %s",
                      info.id, err.message);
            }
        }

        if (!info.data_dir.query_exists(cancellable)) {
            try {
                info.data_dir.make_directory_with_parents();
            } catch (Error err) {
                error("Error creating storage directory for account '%s': %s",
                      info.id, err.message);
            }
        }

        if (!file.query_exists(cancellable)) {
            try {
                yield file.create_async(FileCreateFlags.REPLACE_DESTINATION);
            } catch (Error err) {
                debug("Error creating account info file: %s", err.message);
            }
        }
        KeyFile key_file = new KeyFile();
        key_file.set_value(Geary.Config.GROUP, Geary.Config.CREDENTIALS_METHOD_KEY, info.imap.credentials_method.to_string());
        key_file.set_value(Geary.Config.GROUP, Geary.Config.CREDENTIALS_PROVIDER_KEY, info.imap.credentials_provider.to_string());
        key_file.set_value(Geary.Config.GROUP, Geary.Config.REAL_NAME_KEY, info.primary_mailbox.name);
        key_file.set_value(Geary.Config.GROUP, Geary.Config.PRIMARY_EMAIL_KEY, info.primary_mailbox.address);
        key_file.set_value(Geary.Config.GROUP, Geary.Config.NICKNAME_KEY, info.nickname);
        key_file.set_value(Geary.Config.GROUP, Geary.Config.SERVICE_PROVIDER_KEY, info.service_provider.to_string());
        key_file.set_integer(Geary.Config.GROUP, Geary.Config.ORDINAL_KEY, info.ordinal);
        key_file.set_integer(Geary.Config.GROUP, Geary.Config.PREFETCH_PERIOD_DAYS_KEY, info.prefetch_period_days);
        key_file.set_boolean(Geary.Config.GROUP, Geary.Config.SAVE_SENT_MAIL_KEY, info.save_sent_mail);
        key_file.set_boolean(Geary.Config.GROUP, Geary.Config.USE_EMAIL_SIGNATURE_KEY, info.use_email_signature);
        key_file.set_string(Geary.Config.GROUP, Geary.Config.EMAIL_SIGNATURE_KEY, info.email_signature);
        if (info.alternate_mailboxes != null && info.alternate_mailboxes.size > 0) {
            string[] list = new string[info.alternate_mailboxes.size];
            for (int ctr = 0; ctr < info.alternate_mailboxes.size; ctr++)
                list[ctr] = info.alternate_mailboxes[ctr].to_rfc822_string();

            key_file.set_string_list(Geary.Config.GROUP, Geary.Config.ALTERNATE_EMAILS_KEY, list);
        }

        if (info.service_provider == Geary.ServiceProvider.OTHER) {
            info.imap.save_settings(key_file);
            info.smtp.save_settings(key_file);
        }

        key_file.set_string_list(Geary.Config.GROUP, Geary.Config.DRAFTS_FOLDER_KEY, (info.drafts_folder_path != null
            ? info.drafts_folder_path.as_list().to_array() : new string[] {}));
        key_file.set_string_list(Geary.Config.GROUP, Geary.Config.SENT_MAIL_FOLDER_KEY, (info.sent_mail_folder_path != null
            ? info.sent_mail_folder_path.as_list().to_array() : new string[] {}));
        key_file.set_string_list(Geary.Config.GROUP,Geary. Config.SPAM_FOLDER_KEY, (info.spam_folder_path != null
            ? info.spam_folder_path.as_list().to_array() : new string[] {}));
        key_file.set_string_list(Geary.Config.GROUP, Geary.Config.TRASH_FOLDER_KEY, (info.trash_folder_path != null
            ? info.trash_folder_path.as_list().to_array() : new string[] {}));
        key_file.set_string_list(Geary.Config.GROUP, Geary.Config.ARCHIVE_FOLDER_KEY, (info.archive_folder_path != null
            ? info.archive_folder_path.as_list().to_array() : new string[] {}));

        key_file.set_boolean(Geary.Config.GROUP, Geary.Config.SAVE_DRAFTS_KEY, info.save_drafts);

        string data = key_file.to_data();
        string new_etag;

        try {
            yield file.replace_contents_async(data.data, null, false, FileCreateFlags.NONE,
                cancellable, out new_etag);

            this.engine.add_account(info, true);
        } catch (Error err) {
            debug("Error writing to account info file: %s", err.message);
        }
    }

    /**
     * Deletes an account from disk.  This is used by Geary.Engine and should not
     * normally be invoked directly.
     */
    public async void remove_async(Geary.AccountInformation info, Cancellable? cancellable = null) {
        if (info.data_dir == null) {
            warning("Cannot remove account storage directory; nothing to remove");
        } else {
            yield Geary.Files.recursive_delete_async(info.data_dir, cancellable);
        }

        if (info.config_dir == null) {
            warning("Cannot remove account configuration directory; nothing to remove");
        } else {
            yield Geary.Files.recursive_delete_async(info.config_dir, cancellable);
        }

        try {
            yield info.clear_stored_passwords_async(Geary.ServiceFlag.IMAP | Geary.ServiceFlag.SMTP);
        } catch (Error e) {
            debug("Error clearing SMTP password: %s", e.message);
        }
    }

}
