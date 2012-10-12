# Run 5 parallel requests; ut_magic_redirect should only make 1 request to remote server.
for X in `seq 1 5`
do
	wget http://localhost:4567/SaveMe.umx.uz -O result-$X &
	sleep 2   # This longer pause shows how it sucks to not use caching!
done
# Retrieved files should all match.
wait
cksum result-*
