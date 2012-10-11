# Run 5 parallel requests; ut_magic_redirect should only make 1 request to remote server.
for X in `seq 1 5`
do wget http://localhost:8080/SaveMe.umx.uz -O result-$X &
done
# Retrieved files should all match.
wait
cksum result-*
