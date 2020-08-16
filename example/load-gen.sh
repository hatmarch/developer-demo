ITERATIONS=$1

for (( c=1; c<=$ITERATIONS; c++ ))
do  
   echo "sending event $c"
   cat $DEMO_HOME/example/order-payload.json | oc exec -i -c kafka my-cluster-kafka-0 -n dev-demo-support -- /opt/kafka/bin/kafka-console-producer.sh --broker-list localhost:9092 --topic orders 
done

echo "Done."