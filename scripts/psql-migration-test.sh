./scripts/jq-dep-check.sh

TMPDIR=`mktemp -d 2>/dev/null || mktemp -d -t 'tmpConfigDir'`
DUMPDIR=`mktemp -d 2>/dev/null || mktemp -d -t 'dumpDir'`

cp config/config.json $TMPDIR

echo "Creating databases"
docker exec mattermost-postgres sh -c 'exec echo "CREATE DATABASE migrated; CREATE DATABASE latest;" | exec psql -U mmuser mattermost_test'

echo "Importing postgres dump from version 5.0"
docker exec -i mattermost-postgres psql -U mmuser -d migrated < $(pwd)/scripts/mattermost-postgresql-5.0.sql

echo "Setting up config for db migration"
cat $TMPDIR/config.json | \
    jq '.SqlSettings.DataSource = "postgres://mmuser:mostest@localhost:5432/migrated?sslmode=disable&connect_timeout=10"'| \
    jq '.SqlSettings.DriverName = "postgres"' > $TMPDIR/config.json

echo "Running the migration"
make ARGS="version --config $TMPDIR/config.json" run-cli

echo "Setting up config for fresh db setup"
cat $TMPDIR/config.json | \
    jq '.SqlSettings.DataSource = "postgres://mmuser:mostest@localhost:5432/latest?sslmode=disable&connect_timeout=10"' > $TMPDIR/config.json

echo "Setting up fresh db"
make ARGS="version --config $TMPDIR/config.json" run-cli

for i in "ChannelMembers MentionCountRoot" "ChannelMembers MsgCountRoot" "Channels TotalMsgCountRoot"; do
    a=( $i );
    echo "Ignoring known Postgres mismatch: ${a[0]}.${a[1]}"
    docker exec mattermost-postgres psql -U mmuser -d migrated -c "ALTER TABLE ${a[0]} DROP COLUMN ${a[1]};"
    docker exec mattermost-postgres psql -U mmuser -d latest -c "ALTER TABLE ${a[0]} DROP COLUMN ${a[1]};"
done

echo "Generating dump"
docker exec mattermost-postgres pg_dump --schema-only -d migrated -U mmuser > $DUMPDIR/migrated.sql
docker exec mattermost-postgres pg_dump --schema-only -d latest -U mmuser > $DUMPDIR/latest.sql

echo "Removing databases created for db comparison"
docker exec mattermost-postgres sh -c 'exec echo "DROP DATABASE migrated; DROP DATABASE latest;" | exec psql -U mmuser mattermost_test'

echo "Generating diff"
git diff --word-diff=color $DUMPDIR/migrated.sql $DUMPDIR/latest.sql > $DUMPDIR/diff.txt
diffErrorCode=$?

if [ $diffErrorCode -eq 0 ]; then
    echo "Both schemas are same"
else
    echo "Schema mismatch"
    cat $DUMPDIR/diff.txt
fi
rm -rf $TMPDIR $DUMPDIR

exit $diffErrorCode
