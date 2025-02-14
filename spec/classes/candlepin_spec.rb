require 'spec_helper'

describe 'candlepin' do
  on_supported_os.each do |os, facts|
    context "on #{os}" do
      let(:facts) { facts }

      describe 'default parameters' do
        let :params do
          {db_password: 'testpassword'}
        end

        it { is_expected.to compile.with_all_deps }

        # install
        it { is_expected.to contain_class('candlepin::install') }
        it { is_expected.to contain_package('candlepin').with_ensure('present') }

        if facts[:os]['release']['major'] == '8'
          it { is_expected.to contain_package('pki-core').that_comes_before('Package[candlepin]') }
        end

        # config
        it { is_expected.to contain_class('candlepin::config') }
        it { is_expected.to contain_user('tomcat').with_ensure('present').with_groups([]) }
        it { is_expected.to contain_group('tomcat').with_ensure('present') }
        it do
          verify_concat_fragment_exact_contents(catalogue, 'General Config', [
            'candlepin.environment_content_filtering=true',
            'candlepin.auth.basic.enable=true',
            'candlepin.auth.trusted.enable=false',
            'candlepin.auth.oauth.enable=true',
            'candlepin.auth.oauth.consumer.candlepin.secret=candlepin',
            'candlepin.ca_key=/etc/candlepin/certs/candlepin-ca.key',
            'candlepin.ca_cert=/etc/candlepin/certs/candlepin-ca.crt',
            'candlepin.async.jobs.ExpiredPoolsCleanupJob.schedule=0 0 0 * * ?',
            'candlepin.audit.hornetq.config_path=/etc/candlepin/broker.xml',
            'candlepin.db.database_manage_on_startup=Manage',
          ])
        end
        it { is_expected.to contain_file('/etc/tomcat/tomcat.conf') }

        it do
          verify_exact_contents(catalogue, '/etc/tomcat/tomcat.conf', [
            'TOMCAT_CFG_LOADED="1"',
            'TOMCATS_BASE="/var/lib/tomcats/"',
            'JAVA_HOME="/usr/lib/jvm/jre"',
            'CATALINA_HOME="/usr/share/tomcat"',
            'CATALINA_TMPDIR="/var/cache/tomcat/temp"',
            'JAVA_OPTS="-Xms1024m -Xmx4096m -Dcom.redhat.fips=false"',
            'SECURITY_MANAGER="0"',
          ])
        end

        it { is_expected.to contain_file('/etc/tomcat/login.config') }
        it { is_expected.to contain_file('/etc/tomcat/cert-roles.properties') }
        it { is_expected.to contain_file('/etc/tomcat/conf.d/jaas.conf') }
        it do
          is_expected.to contain_file('/etc/tomcat/cert-users.properties').
            with_content("katelloUser=CN=ActiveMQ Artemis Client, OU=Artemis, O=ActiveMQ, L=AMQ, ST=AMQ, C=AMQ\n")
        end

        it do
          is_expected.to contain_file('/etc/candlepin/broker.xml').
            with_content(/^            <acceptor name="stomp">tcp:\/\/localhost:61613\?protocols=STOMP;useEpoll=false;sslEnabled=true;trustStorePath=\/etc\/candlepin\/certs\/truststore;trustStorePassword=;keyStorePath=\/etc\/candlepin\/certs\/keystore;keyStorePassword=;needClientAuth=true<\/acceptor>/)
        end

        # database
        it { is_expected.not_to contain_class('candlepin::database::mysql') }
        it { is_expected.to contain_class('candlepin::database::postgresql') }
        it { is_expected.not_to contain_cpdb_update('candlepin') }
        it { is_expected.to contain_postgresql__server__db('candlepin') }
        it { is_expected.to contain_postgresql__server__role('candlepin').that_comes_before('Postgresql::Server::Database[candlepin]') }

        it do
          verify_concat_fragment_exact_contents(catalogue, 'PostgreSQL Database Configuration', [
            'jpa.config.hibernate.dialect=org.hibernate.dialect.PostgreSQLDialect',
            'jpa.config.hibernate.connection.driver_class=org.postgresql.Driver',
            'jpa.config.hibernate.connection.url=jdbc:postgresql://localhost:5432/candlepin',
            'jpa.config.hibernate.hbm2ddl.auto=validate',
            'jpa.config.hibernate.connection.username=candlepin',
            'jpa.config.hibernate.connection.password=testpassword',
            'org.quartz.jobStore.misfireThreshold=60000',
            'org.quartz.jobStore.useProperties=false',
            'org.quartz.jobStore.dataSource=myDS',
            'org.quartz.jobStore.tablePrefix=QRTZ_',
            'org.quartz.jobStore.class=org.quartz.impl.jdbcjobstore.JobStoreTX',
            'org.quartz.jobStore.driverDelegateClass=org.quartz.impl.jdbcjobstore.PostgreSQLDelegate',
            'org.quartz.dataSource.myDS.driver=org.postgresql.Driver',
            'org.quartz.dataSource.myDS.URL=jdbc:postgresql://localhost:5432/candlepin',
            'org.quartz.dataSource.myDS.user=candlepin',
            'org.quartz.dataSource.myDS.password=testpassword',
            'org.quartz.dataSource.myDS.maxConnections=5',
          ])
        end

        # service
        it { is_expected.to contain_class('candlepin::service') }
        it { is_expected.to contain_service('tomcat') }
        it { is_expected.to contain_service('tomcat').with_ensure('running') }
      end

      describe 'sensitive parameters' do
        let :params do
          {
            db_type: 'postgresql',
            db_password: sensitive('MY_DB_PASSWORD'),
            keystore_password: sensitive('MY_KEYSTORE_PASSWORD'),
            truststore_password: sensitive('MY_TRUSTSTORE_PASSWORD'),
            ca_key_password: sensitive('MY_CA_KEY_PASSWORD')
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_concat('/etc/candlepin/candlepin.conf') }
        it do
          is_expected.to contain_concat_fragment('PostgreSQL Database Configuration').
            with_content(sensitive(/^jpa.config.hibernate.connection.password=MY_DB_PASSWORD$/)).
            with_content(sensitive(/^org.quartz.dataSource.myDS.password=MY_DB_PASSWORD$/))
        end
        it do
          is_expected.to contain_concat_fragment('General Config').
            with_content(sensitive(/^candlepin.ca_key_password=MY_CA_KEY_PASSWORD$/))
        end
        it do
          is_expected.to contain_file('/etc/candlepin/broker.xml').
            with_content(sensitive(/;keyStorePassword=MY_KEYSTORE_PASSWORD;/)).
            with_content(sensitive(/;trustStorePassword=MY_TRUSTSTORE_PASSWORD;/))
        end
        it do
          is_expected.to contain_file('/etc/tomcat/server.xml').
            with_content(sensitive(/^ *keystorePass="MY_KEYSTORE_PASSWORD"$/))
        end
      end

      describe 'remote database' do
        let :params do
          {
            db_type: 'postgresql',
            db_host: 'psql.example.com',
          }
        end

        context 'without SSL' do
          it { is_expected.to compile.with_all_deps }
          it { is_expected.to contain_concat('/etc/candlepin/candlepin.conf') }
          it do
            is_expected.to contain_concat_fragment('PostgreSQL Database Configuration').
              with_content(sensitive(/^jpa.config.hibernate.connection.url=jdbc:postgresql:\/\/psql\.example\.com:5432/)).
              with_content(sensitive(/^org.quartz.dataSource.myDS.URL=jdbc:postgresql:\/\/psql\.example\.com:5432/))
          end
        end

        context 'with SSL' do
          let(:params) { super().merge(db_ssl: true) }

          it { is_expected.to compile.with_all_deps }
          it { is_expected.to contain_concat('/etc/candlepin/candlepin.conf') }
          it { is_expected.not_to contain_cpdb_update('candlepin') }
          it do
            is_expected.to contain_concat_fragment('PostgreSQL Database Configuration').
              with_content(sensitive(/^jpa.config.hibernate.connection.url=jdbc:postgresql:\/\/psql\.example\.com:5432.*ssl=true$/)).
              with_content(sensitive(/^org.quartz.dataSource.myDS.URL=jdbc:postgresql:\/\/psql\.example\.com:5432.*ssl=true$/))
          end
        end

        context 'with SSL verification disabled' do
          let(:params) { super().merge(db_ssl: true, db_ssl_verify: false) }

          it { is_expected.to compile.with_all_deps }
          it { is_expected.to contain_concat('/etc/candlepin/candlepin.conf') }
          it { is_expected.not_to contain_cpdb_update('candlepin') }
          it do
            is_expected.to contain_concat_fragment('PostgreSQL Database Configuration').
              with_content(sensitive(/^jpa.config.hibernate.connection.url=jdbc:postgresql:\/\/psql\.example\.com:5432.*ssl=true/)).
              with_content(sensitive(/^org.quartz.dataSource.myDS.URL=jdbc:postgresql:\/\/psql\.example\.com:5432.*ssl=true/)).
              with_content(sensitive(/^jpa.config.hibernate.connection.url=.*sslfactory=org.postgresql.ssl.NonValidatingFactory/)).
              with_content(sensitive(/^org.quartz.dataSource.myDS.URL=.*sslfactory=org.postgresql.ssl.NonValidatingFactory/))
          end
        end

        context 'with SSL CA defined' do
          let(:params) { super().merge(db_ssl: true, db_ssl_ca: '/etc/ssl/postgresql.pem') }

          it { is_expected.to compile.with_all_deps }
          it { is_expected.to contain_concat('/etc/candlepin/candlepin.conf') }
          it { is_expected.not_to contain_cpdb_update('candlepin') }
          it do
            is_expected.to contain_concat_fragment('PostgreSQL Database Configuration').
              with_content(sensitive(/^jpa.config.hibernate.connection.url=jdbc:postgresql:\/\/psql\.example\.com:5432.*ssl=true/)).
              with_content(sensitive(/^org.quartz.dataSource.myDS.URL=jdbc:postgresql:\/\/psql\.example\.com:5432.*ssl=true/)).
              with_content(sensitive(/^jpa.config.hibernate.connection.url=.*sslrootcert=\/etc\/ssl\/postgresql.pem/)).
              with_content(sensitive(/^org.quartz.dataSource.myDS.URL=.*sslrootcert=\/etc\/ssl\/postgresql.pem/))
          end
        end

        context 'with db_manage_on_startup Halt' do
          let(:params) { super().merge(db_manage_on_startup: 'Halt') }

          it 'migrates the database' do
            is_expected.to contain_cpdb_update('candlepin')
              .that_subscribes_to(['Package[candlepin]', 'Concat[/etc/candlepin/candlepin.conf]'])
              .that_notifies('Service[tomcat]')
          end
        end

        context 'with db_manage_on_startup Report' do
          let(:params) { super().merge(db_manage_on_startup: 'Report') }

          it 'migrates the database' do
            is_expected.to contain_cpdb_update('candlepin')
              .that_subscribes_to(['Package[candlepin]', 'Concat[/etc/candlepin/candlepin.conf]'])
              .that_notifies('Service[tomcat]')
          end
        end

        context 'with db_manage_on_startup None' do
          let(:params) { super().merge(db_manage_on_startup: 'None') }

          it 'migrates the database' do
            is_expected.to contain_cpdb_update('candlepin')
              .that_subscribes_to(['Package[candlepin]', 'Concat[/etc/candlepin/candlepin.conf]'])
              .that_notifies('Service[tomcat]')
          end
        end
      end

      describe 'selinux' do
        describe 'on' do
          let(:facts) { override_facts(super(), os: {selinux: {enabled: true}}) }

          it { is_expected.to compile.with_all_deps }
          it { is_expected.to contain_selboolean('candlepin_can_bind_activemq_port').that_requires('Package[candlepin-selinux]') }

          if facts[:os]['release']['major'] == '8'
            it { is_expected.to contain_package('candlepin-selinux').that_requires('Package[pki-core]') }
          end
        end

        describe 'off' do
          let(:facts) { override_facts(super(), os: {selinux: {enabled: false}}) }

          it { is_expected.to compile.with_all_deps }
          it { is_expected.not_to contain_selboolean('candlepin_can_bind_activemq_port') }
          it { is_expected.not_to contain_package('candlepin-selinux') }
        end
      end

      describe 'with additional logging' do
        describe 'with org.candlepin set to DEBUG' do
          let(:params) do
            {
              loggers: {
                'org.candlepin' => 'DEBUG',
              },
            }
          end

          it do
            is_expected.to contain_concat__fragment('General Config')
              .with_content(sensitive(%r{^log4j\.logger\.org\.candlepin=DEBUG$}))
          end
        end

        describe 'with various loggers set' do
          let(:params) do
            {
              loggers: {
                'org.candlepin'                             => 'DEBUG',
                'org.candlepin.resource.ConsumerResource'   => 'WARN',
                'org.candlepin.resource.HypervisorResource' => 'WARN',
                'org.hibernate.internal.SessionImpl'        => 'FATAL',
              },
            }
          end

          it do
            is_expected.to contain_concat__fragment('General Config')
              .with_content(sensitive(%r{^log4j\.logger\.org\.candlepin=DEBUG$}))
              .with_content(sensitive(%r{^log4j\.logger\.org\.candlepin\.resource\.ConsumerResource=WARN$}))
              .with_content(sensitive(%r{^log4j\.logger\.org\.candlepin\.resource\.HypervisorResource=WARN$}))
          end
        end
      end

      describe 'with custom adapter module' do
        let :params do
          {adapter_module: 'my.custom.adapter_module'}
        end

        it { is_expected.to compile.with_all_deps }

        it do
          is_expected.to contain_concat__fragment('General Config').
            with_content(sensitive(/^module.config.adapter_module=my.custom.adapter_module$/))
        end
      end

      describe 'with ssl_port' do
        let :params do
          {ssl_port: 9070}
        end

        it { is_expected.to compile.with_all_deps }
        it do
          is_expected.to contain_file("/etc/tomcat/server.xml").
            with_content(/^    <Connector port="9070"/).
            with_content(/^               address="localhost"/).
            with_content(/^               protocol="HTTP\/1.1"/).
            with_content(/^               SSLEnabled="true"/)
        end
      end

      describe 'with tls_versions' do
        let :params do
          {tls_versions: ['1.2', '1.3']}
        end

        it { is_expected.to compile.with_all_deps }
        it do
          is_expected.to contain_file("/etc/tomcat/server.xml").
            with_content(/sslProtocol="TLSv1.2,TLSv1.3"/).
            with_content(/sslEnabledProtocols="TLSv1.2,TLSv1.3"/)
        end
      end

      describe 'with java params' do
        let :params do
          {
            java_package: 'java-17-openjdk',
            java_home: '/usr/lib/jvm/jre-17'
          }
        end

        it { is_expected.to contain_package('java-17-openjdk').that_comes_before('Service[tomcat]') }

        it do
          is_expected.to contain_file("/etc/tomcat/tomcat.conf").
            with_content(/JAVA_HOME="\/usr\/lib\/jvm\/jre-17"/)
        end
      end

      describe 'with mysql' do
        let :params do
          {
            db_type: 'mysql',
            db_password: 'testpassword',
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_class('candlepin::database::postgresql') }
        it { is_expected.to contain_class('candlepin::database::mysql') }
        it do
          verify_concat_fragment_exact_contents(catalogue, 'Mysql Database Configuration', [
            'jpa.config.hibernate.dialect=org.hibernate.dialect.MySQLDialect',
            'jpa.config.hibernate.connection.driver_class=com.mysql.jdbc.Driver',
            'jpa.config.hibernate.connection.url=jdbc:mysql://localhost:3306/candlepin',
            'jpa.config.hibernate.hbm2ddl.auto=validate',
            'jpa.config.hibernate.connection.username=candlepin',
            'jpa.config.hibernate.connection.password=testpassword',
            'org.quartz.jobStore.misfireThreshold=60000',
            'org.quartz.jobStore.useProperties=false',
            'org.quartz.jobStore.dataSource=myDS',
            'org.quartz.jobStore.tablePrefix=QRTZ_',
            'org.quartz.jobStore.class=org.quartz.impl.jdbcjobstore.JobStoreTX',
            'org.quartz.jobStore.driverDelegateClass=org.quartz.impl.jdbcjobstore.StdJDBCDelegate',
            'org.quartz.dataSource.myDS.driver=com.mysql.jdbc.Driver',
            'org.quartz.dataSource.myDS.URL=jdbc:mysql://localhost:3306/candlepin',
            'org.quartz.dataSource.myDS.user=candlepin',
            'org.quartz.dataSource.myDS.password=testpassword',
            'org.quartz.dataSource.myDS.maxConnections=5',
          ])
        end
      end

      describe 'with enable_hbm2ddl_validate = false' do
        let :params do
          {enable_hbm2ddl_validate: false}
        end

        context 'with postgresql' do
          it { is_expected.to compile.with_all_deps }
          it do
            is_expected.to contain_concat__fragment('PostgreSQL Database Configuration').
              without_content(/jpa.config.hibernate.hbm2ddl.auto=validate/)
          end
        end

        context 'with mysql' do
          let(:params) { super().merge(db_type: 'mysql') }
          it { is_expected.to compile.with_all_deps }
          it do
            is_expected.to contain_concat__fragment('Mysql Database Configuration').
              without_content(/jpa.config.hibernate.hbm2ddl.auto=validate/)
          end
        end
      end

      describe 'notify' do
        let :pre_condition do
          <<-EOS
          exec { 'notification':
            command => '/bin/true',
            notify  => Class['candlepin'],
          }

          exec { 'dependency':
            command => '/bin/true',
            require => Class['candlepin'],
          }
          EOS
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_exec('notification').that_notifies('Service[tomcat]') }
        it { is_expected.to contain_exec('dependency').that_requires('Service[tomcat]') }
      end
    end
  end
end
