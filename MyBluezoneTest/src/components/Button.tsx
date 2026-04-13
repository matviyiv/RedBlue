import React from 'react';
import {TouchableOpacity, Text, StyleSheet} from 'react-native';

interface Props { title: string; onPress: () => void; }

export const Button: React.FC<Props> = ({title, onPress}) => (
  <TouchableOpacity style={styles.btn} onPress={onPress}>
    <Text style={styles.text}>{title}</Text>
  </TouchableOpacity>
);

const styles = StyleSheet.create({
  btn: {backgroundColor: '#007AFF', padding: 12, borderRadius: 8},
  text: {color: '#fff', fontWeight: '600'},
});
